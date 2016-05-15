{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Data.Bifunctor
import Data.Char
import Data.Profunctor
import Data.Foldable

import qualified Data.ByteString.Short as BS.S
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T.E
import qualified Data.Vector as V
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Unboxed as VU
import           Data.Vector.Algorithms.Intro (sort)
import qualified Control.Foldl as Foldl
import           Control.Foldl (FoldM, Fold)

import           Pipes
import           Pipes.Safe
import qualified Pipes.Prelude as P.P
import qualified Pipes.Text.Encoding as P.T

import Utils
import Types
import Tokenise
import SimplIR.TREC as TREC
import AccumPostings
import DataSource
import DiskIndex

dsrcs = map LocalFile [ "data/robust04/docs/ft91.dat.gz"
                      -- , "data/robust04/docs/ft94.dat.gz"
                      ]
compression = Just GZip

main :: IO ()
main = do
    let normTerms :: [(Term, p)] -> [(Term, p)]
        normTerms = filterTerms . caseNorm
          where
            caseNorm = map (first $ Term . T.filter isAlpha . T.toCaseFold . getTerm)
            filterTerms = filter ((>2) . T.length . getTerm . fst)
            --filterTerms = filter (\(k,_) -> k `HS.member` takeTerms)

    let docs :: Producer TREC.Document (SafeT IO) ()
        docs =
            mapM_ (trecDocuments' . P.T.decodeUtf8 . decompress compression . produce) dsrcs

    let chunkIndexes :: Producer (FragmentIndex (VU.Vector Position)) (SafeT IO) ()
        chunkIndexes =
                consumePostings 10000
             $  docs
            >-> cat'                                          @TREC.Document
            >-> P.P.map (\d -> (DocName $ BS.S.toShort $ T.E.encodeUtf8 $ TREC.docNo d, TREC.docText d))
            >-> cat'                                          @(DocumentName, T.Text)
            >-> P.P.map (fmap tokeniseWithPositions)
            >-> cat'                                          @(DocumentName, [(Term, Position)])
            >-> P.P.map (fmap normTerms)
            >-> cat'                                          @(DocumentName, [(Term, Position)])
            >-> zipWithList [DocId 0..]
            >-> cat'                                          @(DocumentId, (DocumentName, [(Term, Position)]))
            >-> P.P.map (\(docId, (docName, postings)) ->
                          ((docId, docName),
                            toPostings docId
                            $ M.assocs
                            $ foldTokens accumPositions postings))
            >-> cat'                                          @((DocumentId, DocumentName), TermPostings (VU.Vector Position))

    chunks <- runSafeT $ P.P.toListM $ for (chunkIndexes >-> zipWithList [0..]) $ \(n, (docIds, postings)) -> do
        liftIO $ print (n, M.size docIds)
        let indexPath = "index-"++show n
        liftIO $ DiskIndex.fromDocuments indexPath (M.toList docIds) (fmap V.toList postings)
        yield indexPath

    chunkIdxs <- mapM DiskIndex.open chunks
              :: IO [DiskIndex (DocumentName, DocumentLength) (VU.Vector Position)]
    putStrLn $ "Merging "++show (length chunkIdxs)++" chunks"
    DiskIndex.merge "index" chunkIdxs

type SavedPostings p = M.Map Term (V.Vector (Posting p))
type FragmentIndex p =
    ( M.Map DocumentId (DocumentName, DocumentLength)
    , SavedPostings p)

zipWithList :: Monad m => [i] -> Pipe a (i,a) m r
zipWithList = go
  where
    go []     = error "zipWithList: Reached end of list"
    go (i:is) = do
        x <- await
        yield (i, x)
        go is

foldChunks :: Monad m => Int -> FoldM m a b -> Producer a m () -> Producer b m ()
foldChunks chunkSize (Foldl.FoldM step initial extract) = start
  where
    start prod = do
        acc <- lift initial
        go chunkSize acc prod

    go 0 acc prod = do
        lift (extract acc) >>= yield
        start prod
    go n acc prod = do
        mx <- lift $ next prod
        case mx of
          Right (x, prod') -> do
              acc' <- lift $ step acc x
              go (n-1 :: Int) acc' prod'
          Left r -> lift (extract acc) >>= yield

consumePostings :: (Monad m, Ord p)
                => Int
                -> Producer ((DocumentId, DocumentName), TermPostings p) m ()
                -> Producer (FragmentIndex p) m ()
consumePostings chunkSize =
    foldChunks chunkSize (Foldl.generalize consumePostings')

consumePostings' :: (Ord p)
                 => Fold ((DocumentId, DocumentName), TermPostings p)
                         (FragmentIndex p)
consumePostings' =
    (,) <$> docMeta <*> lmap snd postings
  where
    docMeta  = lmap (\((docId, docName), postings) -> M.singleton docId (docName, DocLength $ sum $ fmap length postings))
                      Foldl.mconcat
    postings = fmap (M.map $ VG.modify sort . fromFoldable) foldPostings

fromFoldable :: (Foldable f, VG.Vector v a)
             => f a -> v a
fromFoldable xs = VG.fromListN (length xs) (toList xs)
