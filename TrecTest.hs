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
                      --, "data/robust04/docs/ft94.dat.gz"
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

    (docIds, postings) <-
            runSafeT
         $  consumePostings
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

    DiskIndex.fromDocuments "index" (M.toList docIds) (fmap V.toList postings)

type SavedPostings p = M.Map Term (V.Vector (Posting p))

zipWithList :: Monad m => [i] -> Pipe a (i,a) m r
zipWithList = go
  where
    go []     = error "zipWithList: Reached end of list"
    go (i:is) = do
        x <- await
        yield (i, x)
        go is

consumePostings :: (Monad m, Ord p)
                => Producer ((DocumentId, DocumentName), TermPostings p) m ()
                -> m ( M.Map DocumentId (DocumentName, DocumentLength)
                     , SavedPostings p)
consumePostings =
    foldProducer $ (,) <$> docMeta
                       <*> lmap snd postings
  where
    docMeta  = Foldl.generalize
               $ lmap (\((docId, docName), postings) -> M.singleton docId (docName, DocLength $ sum $ fmap length postings))
                      Foldl.mconcat
    postings = Foldl.generalize $ fmap (M.map $ VG.modify sort . fromFoldable) foldPostings

fromFoldable :: (Foldable f, VG.Vector v a)
             => f a -> v a
fromFoldable xs = VG.fromListN (length xs) (toList xs)
