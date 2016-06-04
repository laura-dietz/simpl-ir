{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Control.Monad.State.Strict hiding ((>=>))
import Data.Bifunctor
import Data.Maybe
import Data.Monoid
import Data.Profunctor
import Data.Tuple
import Data.Char

import Data.Binary
import Numeric.Log
import qualified Data.ByteString.Lazy.Char8 as BS.L
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Control.Foldl as Foldl

import           Pipes
import           Pipes.Safe
import qualified Pipes.Prelude as P.P
import qualified Pipes.ByteString as P.BS

import Options.Applicative

import qualified Data.SmallUtf8 as Utf8
import Utils
import Types
import Term
import Tokenise
import DataSource
import TopK
import qualified SimplIR.TrecStreaming as Trec
import RetrievalModels.QueryLikelihood

type QueryId = String

scoreMode :: Parser (IO ())
scoreMode =
    score
      <$> optQueryFile
      <*> option auto (metavar "N" <> long "count" <> short 'n' <> value 10)
      <*> some (argument (LocalFile <$> str) (metavar "FILE" <> help "TREC input file"))

corpusStatsMode :: Parser (IO ())
corpusStatsMode =
    corpusStats
      <$> optQueryFile
      <*> some (argument (LocalFile <$> str) (metavar "FILE" <> help "TREC input file"))

modes :: Parser (IO ())
modes = subparser
    $  command "score" (info scoreMode fullDesc)
    <> command "corpus-stats" (info corpusStatsMode fullDesc)

type QueryFile = FilePath

optQueryFile :: Parser QueryFile
optQueryFile =
    option str (metavar "FILE" <> long "query" <> short 'q' <> help "query file")

readQueries :: QueryFile -> IO (M.Map QueryId [Term])
readQueries fname = M.unions . mapMaybe parse . lines <$> readFile fname
  where
    parse "" = Nothing
    parse line
      | (qid, body) <- span (/= '\t') line
      = Just $ M.singleton qid (map Term.fromString $ words body)

compression = Just Lzma

main :: IO ()
main = do
    mode <- execParser $ info (helper <*> modes) fullDesc
    mode

corpusStats :: QueryFile -> [DataLocation] -> IO ()
corpusStats queryFile docs = do
    queries <- readQueries queryFile
    let queryTerms = foldMap S.fromList queries
    runSafeT $ do
        idx@(termFreqs, collLength) <-
                foldProducer (Foldl.generalize indexPostings)
             $  streamingDocuments docs >-> normalizationPipeline
            >-> cat'                                @(DocumentName, [(Term, Position)])
            >-> P.P.map (second $ map fst)
            >-> cat'                                @(DocumentName, [Term])
            >-> P.P.map (second $ filter ((`S.member` queryTerms)))

        liftIO $ putStrLn $ "Indexed "++show collLength++" documents with "++show (M.size termFreqs)++" terms"
        liftIO $ BS.L.writeFile "background" $ encode idx

type CollectionLength = Int
type CorpusStats = ( M.Map Term TermFrequency
                   , CollectionLength
                   )

indexPostings :: Foldl.Fold (DocumentName, [Term]) CorpusStats
indexPostings =
    (,)
      <$> lmap snd termFreqs
      <*> lmap (const 1) Foldl.sum
  where
    termFreqs :: Foldl.Fold [Term] (M.Map Term TermFrequency)
    termFreqs =
          Foldl.handles traverse
        $ lmap (\term -> M.singleton term (TermFreq 1))
        $ mconcatMaps

score :: QueryFile -> Int -> [DataLocation] -> IO ()
score queryFile resultCount docs = do
    queries <- readQueries queryFile

    -- load background statistics
    (termFreqs, collLength) <- decode <$> BS.L.readFile "background"
        :: IO CorpusStats
    let getTermFreq term = maybe mempty id $ M.lookup term termFreqs
        smoothing = Dirichlet 2500 ((\n -> (n + 0.5) / (realToFrac collLength + 1)) . getTermFrequency . getTermFreq)


    let queryFolds :: Foldl.Fold (DocumentName, [Term])
                                 (M.Map QueryId [(Score, DocumentName)])
        queryFolds = sequenceA $ fmap queryFold queries

        queryFold :: [Term] -> Foldl.Fold (DocumentName, [Term]) [(Score, DocumentName)]
        queryFold queryTerms =
            let queryTerms' :: M.Map Term Int
                queryTerms' = M.fromListWith (+) $ zip queryTerms (repeat 1)
                scoreTerms :: [Term] -> Score
                scoreTerms terms =
                    let docLength = DocLength $ length terms
                        terms' = zip terms (repeat 1)
                    in queryLikelihood smoothing (M.assocs queryTerms') docLength terms'
            in lmap (swap . second scoreTerms) $ topK resultCount

    runSafeT $ do
        results <-
                foldProducer (Foldl.generalize queryFolds)
             $  streamingDocuments docs
            >-> normalizationPipeline
            >-> cat'                                          @(DocumentName, [(Term, Position)])
            -- >-> P.P.filter (any (`S.member` allQueryTerms) . map fst . snd)
            >-> P.P.map (second $ map fst)
            >-> cat'                                          @(DocumentName, [Term])

        liftIO $ putStrLn $ unlines
            [ unwords [ qid, "Q0", Utf8.toString docName, show rank, show score, "simplir" ]
            | (qid, scores) <- M.toList results
            , (rank, (Exp score, DocName docName)) <- zip [1..] scores
            ]
        return ()

type ArchiveName = T.Text

streamingDocuments :: [DataLocation]
                   -> Producer (ArchiveName, Trec.StreamItem) (SafeT IO) ()
streamingDocuments dsrcs =
    mapM_ (\src -> do
                bs <- P.BS.toLazyM (decompress compression $ produce src)
                mapM_ (yield . (getFileName src,)) (Trec.readItems $ BS.L.toStrict bs)
          ) dsrcs

normalizationPipeline
    :: Monad m
    => Pipe (ArchiveName, Trec.StreamItem)
            (DocumentName, [(Term, Position)]) m ()
normalizationPipeline =
          P.P.mapFoldable
              (\(archive, d) -> do
                    body <- Trec.body d
                    visible <- Trec.cleanVisible body
                    let docName =
                            DocName $ Utf8.fromText $ archive <> Trec.getDocumentId (Trec.documentId d)
                    return (docName, visible))
      >-> cat'                                          @(DocumentName, T.Text)
      >-> P.P.map (fmap tokeniseWithPositions)
      >-> cat'                                          @(DocumentName, [(T.Text, Position)])
      >-> P.P.map (fmap normTerms)
      >-> cat'                                          @(DocumentName, [(Term, Position)])
  where
    normTerms :: [(T.Text, p)] -> [(Term, p)]
    normTerms = map (first Term.fromText) . filterTerms . caseNorm
      where
        filterTerms = filter ((>2) . T.length . fst)
        caseNorm = map (first $ T.filter isAlpha . T.toCaseFold)
