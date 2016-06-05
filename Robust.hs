{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}

import Control.Monad.State.Strict hiding ((>=>))
import Data.Bifunctor
import Data.Foldable (fold, toList)
import Data.Maybe
import Data.Monoid
import Data.Profunctor
import Data.Char
import GHC.Generics
import System.IO
import System.FilePath

import Data.Binary
import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import Numeric.Log hiding (sum)
import qualified Data.ByteString.Lazy.Char8 as BS.L
import qualified Data.Map.Strict as M
import qualified Data.HashSet as HS
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Control.Foldl as Foldl
import           Control.Foldl (Fold)
import qualified Data.Vector as V
import qualified Data.Vector.Generic as V.G
import qualified Data.Vector.Unboxed as V.U
import           Data.Vector.Algorithms.Heap (sort)

import           Pipes
import           Pipes.Safe
import qualified Pipes.Text.Encoding as P.T
import qualified Pipes.Prelude as P.P

import Options.Applicative

import qualified Data.SmallUtf8 as Utf8
import Utils
import AccumPostings
import Types
import Term
import Tokenise
import DataSource
import qualified DiskIndex
import TopK
import qualified SimplIR.TREC as Trec
import RetrievalModels.QueryLikelihood

type QueryId = String
type StatsFile = FilePath

inputFiles :: Parser (IO [DataSource])
inputFiles =
    concatThem <$> some (argument (parse <$> str) (metavar "FILE" <> help "TREC input file"))
  where
    concatThem :: [IO [DataSource]] -> IO [DataSource]
    concatThem = fmap concat . sequence

    parse :: String -> IO [DataSource]
    parse ('@':rest) = map (DataSource (Just GZip) . LocalFile) . lines <$> readFile rest
    parse fname      = return [DataSource (Just GZip) (LocalFile fname)]

streamMode :: Parser (IO ())
streamMode =
    score
      <$> optQueryFile
      <*> option auto (metavar "N" <> long "count" <> short 'n' <> value 10)
      <*> option str (metavar "FILE" <> long "stats" <> short 's'
                      <> help "background corpus statistics file")
      <*> inputFiles

indexMode :: Parser (IO ())
indexMode =
    buildIndex
      <$> inputFiles

corpusStatsMode :: Parser (IO ())
corpusStatsMode =
    corpusStats
      <$> optQueryFile
      <*> option str (metavar "FILE" <> long "output" <> short 'o'
                      <> help "output file path")
      <*> inputFiles


modes :: Parser (IO ())
modes = subparser
    $  command "score" (info streamMode fullDesc)
    <> command "corpus-stats" (info corpusStatsMode fullDesc)
    <> command "index" (info indexMode fullDesc)

type QueryFile = FilePath

optQueryFile :: Parser QueryFile
optQueryFile =
    option str (metavar "FILE" <> long "query" <> short 'q' <> help "query file")

readQueries :: QueryFile -> IO (M.Map QueryId [Term])
readQueries fname = do
    queries <- M.unions . mapMaybe parse . lines <$> readFile fname
    let allTerms = foldMap S.fromList queries
    hPutStrLn stderr $ show (M.size queries)++" queries with "++show (S.size allTerms)++" unique terms"
    return queries
  where
    parse "" = Nothing
    parse line
      | (qid, body) <- span (/= '\t') line
      = Just $ M.singleton qid (map Term.fromString $ words body)

main :: IO ()
main = do
    mode <- execParser $ info (helper <*> modes) fullDesc
    mode

corpusStats :: QueryFile -> StatsFile -> IO [DataSource] -> IO ()
corpusStats queryFile outputFile readDocLocs = do
    docs <- readDocLocs
    queries <- readQueries queryFile
    let queryTerms = foldMap S.fromList queries
    runSafeT $ do
        stats <-
                foldProducer (Foldl.generalize foldCorpusStats)
             $  trecDocuments docs >-> normalizationPipeline
            >-> cat'                                @((ArchiveName, DocumentName, DocumentLength), [(Term, Position)])
            >-> P.P.map (second $ map fst)
            >-> cat'                                @((ArchiveName, DocumentName, DocumentLength), [Term])
            >-> P.P.map (second $ filter ((`S.member` queryTerms)))

        liftIO $ putStrLn $ "Indexed "++show (corpusCollectionLength stats)
                          ++" documents with "++show (M.size $ corpusTermFreqs stats)++" terms"
        liftIO $ BS.L.writeFile outputFile $ encode stats
        liftIO $ putStrLn $ "Saw "++show (fold $ corpusTermFreqs stats)++" term occurrences"

-- | How many documents in a collection?
type CollectionLength = Int
data CorpusStats = CorpusStats { corpusTermFreqs :: !(M.Map Term TermFrequency)
                               , corpusCollectionLength :: !CollectionLength
                               }
                 deriving (Generic)

instance Binary CorpusStats
instance Monoid CorpusStats where
    mempty = CorpusStats mempty 0
    a `mappend` b =
        CorpusStats { corpusTermFreqs = corpusTermFreqs a <> corpusTermFreqs b
                    , corpusCollectionLength = corpusCollectionLength a + corpusCollectionLength b
                    }

foldCorpusStats :: Foldl.Fold ((ArchiveName, DocumentName, DocumentLength), [Term]) CorpusStats
foldCorpusStats =
    CorpusStats
      <$> lmap snd termFreqs
      <*> lmap (const 1) Foldl.sum
  where
    termFreqs :: Foldl.Fold [Term] (M.Map Term TermFrequency)
    termFreqs =
          Foldl.handles traverse
        $ lmap (\term -> M.singleton term (TermFreq 1))
        $ mconcatMaps

score :: QueryFile -> Int -> FilePath -> IO [DataSource] -> IO ()
score queryFile resultCount statsFile readDocLocs = do
    docs <- readDocLocs
    queries <- readQueries queryFile

    -- load background statistics
    CorpusStats termFreqs collLength <- decode <$> BS.L.readFile statsFile
    let getTermFreq term = maybe mempty id $ M.lookup term termFreqs
        smoothing = Dirichlet 2500 ((\n -> (n + 0.5) / (realToFrac collLength + 1)) . getTermFrequency . getTermFreq)


    let queriesFold :: Foldl.Fold ((ArchiveName, DocumentName, DocumentLength), [Term])
                                  (M.Map QueryId [(Score, (ArchiveName, DocumentName))])
        queriesFold = traverse queryFold queries

        queryFold :: [Term] -> Foldl.Fold ((ArchiveName, DocumentName, DocumentLength), [Term])
                                          [(Score, (ArchiveName, DocumentName))]
        queryFold queryTerms =
              Foldl.handles (Foldl.filtered (\(_, docTerms) -> any (`M.member` queryTerms') docTerms))
            $ lmap scoreTerms
            $ topK resultCount
          where
            queryTerms' :: M.Map Term Int
            queryTerms' = M.fromListWith (+) $ zip queryTerms (repeat 1)

            scoreTerms :: ((ArchiveName, DocumentName, DocumentLength), [Term])
                       -> (Score, (ArchiveName, DocumentName))
            scoreTerms ((archive, docName, docLength), docTerms) =
                let docTerms' = zip docTerms (repeat 1)
                in ( queryLikelihood smoothing (M.assocs queryTerms') docLength docTerms'
                   , (archive, docName)
                   )

    runSafeT $ do
        results <-
                foldProducer (Foldl.generalize queriesFold)
             $  trecDocuments docs
            >-> normalizationPipeline
            >-> cat'                                          @((ArchiveName, DocumentName, DocumentLength), [(Term, Position)])
            >-> P.P.map (second $ map fst)
            >-> cat'                                          @((ArchiveName, DocumentName, DocumentLength), [Term])

        liftIO $ putStrLn $ unlines
            [ unwords [ qid, T.unpack archive, Utf8.toString docName, show rank, show score, "simplir" ]
            | (qid, scores) <- M.toList results
            , (rank, (Exp score, (archive, DocName docName))) <- zip [1..] scores
            ]
        return ()

buildIndex :: IO [DataSource] -> IO ()
buildIndex readDocLocs = do
    docs <- readDocLocs

    let chunkIndexes :: Producer (FragmentIndex (V.U.Vector Position)) (SafeT IO) ()
        chunkIndexes =
                foldChunks 1000 (Foldl.generalize $ indexPostings (TermFreq . V.G.length))
             $  trecDocuments docs
            >-> normalizationPipeline
            >-> cat'                                              @( (ArchiveName, DocumentName, DocumentLength)
                                                                  , [(Term, Position)] )
            >-> zipWithList [DocId 0..]
            >-> cat'                                              @( DocumentId
                                                                  , ( (ArchiveName, DocumentName, DocumentLength)
                                                                    , [(Term, Position)] )
                                                                  )
            >-> P.P.map (\(docId, ((archive, docName, docLen), postings)) ->
                          ( (docId, archive, docName, docLen)
                          , toPostings docId
                            $ M.assocs
                            $ foldTokens accumPositions postings
                          ))
            >-> cat'                                              @( (DocumentId, ArchiveName, DocumentName, DocumentLength)
                                                                   , [(Term, Posting (V.U.Vector Position))]
                                                                   )

    chunks <- runSafeT $ P.P.toListM $ for (chunkIndexes >-> zipWithList [0..]) $ \(n, (docIds, postings, termFreqs, collLength)) -> do
        liftIO $ print (n, M.size docIds)
        let indexPath = "index-"++show n
        liftIO $ DiskIndex.fromDocuments indexPath (M.toList docIds) (fmap V.toList postings)
        yield (indexPath, (termFreqs, collLength))

    chunkIdxs <- mapM DiskIndex.open $ map fst chunks
              :: IO [DiskIndex.DiskIndex (ArchiveName, DocumentName, DocumentLength) (V.U.Vector Position)]
    putStrLn $ "Merging "++show (length chunkIdxs)++" chunks"
    DiskIndex.merge "index" chunkIdxs

    let collLength = sum $ map (snd . snd) chunks
        termFreqs = M.unionsWith (<>) $ map (fst . snd) chunks
    BS.L.writeFile ("index" </> "coll-length") $ encode (CorpusStats termFreqs collLength)
    return ()

type SavedPostings p = M.Map Term (V.Vector (Posting p))
type FragmentIndex p =
    ( M.Map DocumentId (ArchiveName, DocumentName, DocumentLength)
    , SavedPostings p
    , M.Map Term TermFrequency
    , CollectionLength)

indexPostings :: forall p. (Ord p)
              => (p -> TermFrequency)
              -> Fold ( (DocumentId, ArchiveName, DocumentName, DocumentLength)
                      , [(Term, Posting p)])
                      (FragmentIndex p)
indexPostings getTermFreq =
    (,,,)
      <$> docMeta
      <*> lmap snd postings
      <*> lmap snd termFreqs
      <*> lmap fst collLength
  where
    docMeta  = lmap (\((docId, archive, docName, docLen), _postings) -> M.singleton docId (archive, docName, docLen))
                      Foldl.mconcat
    postings = fmap (M.map $ V.G.modify sort . fromFoldable) foldPostings

    termFreqs :: Fold [(Term, Posting p)] (M.Map Term TermFrequency)
    termFreqs = Foldl.handles traverse
                $ lmap (\(term, ps) -> M.singleton term (getTermFreq $ postingBody ps))
                $ mconcatMaps

    collLength = lmap (\(_, _, _, DocLength c) -> c) Foldl.sum

type ArchiveName = T.Text

trecDocuments :: [DataSource]
              -> Producer ((ArchiveName, DocumentName), T.Text) (SafeT IO) ()
trecDocuments dsrcs =
    mapM_ (\dsrc -> Trec.trecDocuments' (P.T.decodeUtf8 $ dataSource dsrc)
                    >-> P.P.map (\d -> ( ( getFileName $ dsrcLocation dsrc
                                         , DocName $ Utf8.fromText $ Trec.docNo d)
                                       , Trec.docText d)))
          dsrcs

normalizationPipeline
    :: Monad m
    => Pipe ((ArchiveName, DocumentName), T.Text)
            ((ArchiveName, DocumentName, DocumentLength), [(Term, Position)]) m ()
normalizationPipeline =
          cat'                                          @((ArchiveName, DocumentName), T.Text)
      >-> P.P.map (fmap $ T.map killPunctuation)
      >-> P.P.map (fmap tokeniseWithPositions)
      >-> cat'                                          @((ArchiveName, DocumentName), [(T.Text, Position)])
      >-> P.P.map (\((archive, docName), terms) ->
                      let docLen = DocLength $ length $ filter (not . T.all (not . isAlphaNum) . fst) terms
                      in ((archive, docName, docLen), terms))
      >-> cat'                                          @( (ArchiveName, DocumentName, DocumentLength)
                                                         , [(T.Text, Position)])
      >-> P.P.map (fmap normTerms)
      >-> cat'                                          @( (ArchiveName, DocumentName, DocumentLength)
                                                         , [(Term, Position)])
  where
    normTerms :: [(T.Text, p)] -> [(Term, p)]
    normTerms = map (first Term.fromText) . filterTerms . caseNorm
      where
        filterTerms = filter ((>2) . T.length . fst)
        caseNorm = map (first $ T.filter isAlpha . T.toCaseFold)

    killPunctuation c
      | c `HS.member` chars = ' '
      | otherwise           = c
      where chars = HS.fromList "\t\n\r;\"&/:!#?$%()@^*+-,=><[]{}|`~_`"

fromFoldable :: (Foldable f, V.G.Vector v a)
             => f a -> v a
fromFoldable xs = V.G.fromListN (length xs) (toList xs)
