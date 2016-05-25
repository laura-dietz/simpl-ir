module TopK ( topK, topK' ) where

import Data.Foldable
import Data.Profunctor
import qualified Control.Foldl as Fold
import qualified Data.Heap as H
import Data.Ord

data Accum a = Accum { insertions :: !Int
                       -- ^ insertions until next threshold update
                     , threshold  :: !(Maybe a)
                       -- ^ current threshold
                     , heap       :: !(H.Heap a)
                     }

topK :: Ord a => Int -> Fold.Fold a [a]
topK = topK' 10000
{-# INLINE topK #-}

topK' :: Ord a => Int -> Int -> Fold.Fold a [a]
topK' updatePeriod k = dimap Down (map unDown) (minK updatePeriod k)
  where unDown (Down x) = x
{-# INLINE topK' #-}

minK :: Ord a => Int -> Int -> Fold.Fold a [a]
minK updatePeriod k =
    Fold.Fold step accum0 (toList . heap)
  where
    accum0 = Accum updatePeriod Nothing H.empty

    -- doesn't make threshold
    step acc@(Accum _ (Just thresh) _) x
      | x < thresh = acc
    -- update threshold
    step acc@(Accum 0 mthresh heap) x =
        let (heap', rest) = H.splitAt (k-1) heap
            threshold'    = fst <$> H.uncons rest
            acc'          = acc { insertions = updatePeriod
                                , threshold  = threshold'
                                , heap       = maybe id H.insert threshold' heap'
                                }
        in step acc' x
    -- otherwise just insert it
    step acc x =
        acc { heap = H.take k $ H.insert x (heap acc) }
{-# INLINE minK #-}
