#include "inline.hs"

-- |
-- Module      : Streamly.Internal.Data.Stream.StreamD.Type
-- Copyright   : (c) 2018 Composewell Technologies
--               (c) Roman Leshchinskiy 2008-2010
-- License     : BSD-3-Clause
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC

-- The stream type is inspired by the vector package.  A few functions in this
-- module have been originally adapted from the vector package (c) Roman
-- Leshchinskiy. See the notes in specific functions.

module Streamly.Internal.Data.Stream.StreamD.Type
    (
    -- * The stream type
      Step (..)
    -- XXX UnStream is exported to avoid a performance issue in concatMap if we
    -- use the pattern synonym "Stream".
    , Stream (Stream, UnStream)

    -- * Primitives
    , nilM
    , consM
    , uncons

    -- * From Unfold
    , unfold

    -- * From Values
    , fromPure
    , fromEffect

    -- * From Containers
    , fromList

    -- * Conversions From/To
    , fromStreamK
    , toStreamK

    -- * Running a 'Fold'
    , fold
    , foldBreak
    , foldContinue
    , foldEither

    -- * Right Folds
    , foldrM
    , foldrMx
    , foldr
    , foldrS

    -- * Left Folds
    , foldl'
    , foldlM'
    , foldlx'
    , foldlMx'

    -- * Special Folds
    , drain

    -- * To Containers
    , toList

    -- * Multi-stream folds
    , eqBy
    , cmpBy

    -- * Transformations
    , map
    , mapM
    , take
    , takeWhile
    , takeWhileM
    , takeEndBy
    , takeEndByM

    -- * Nesting
    , ConcatMapUState (..)
    , unfoldMany
    , concatMap
    , concatMapM
    , FoldMany (..) -- for inspection testing
    , FoldManyPost (..)
    , foldMany
    , foldManyPost
    , refoldMany
    , chunksOf
    )
where

import Control.Applicative (liftA2)
import Control.Monad.Catch (MonadThrow, throwM)
import Control.Monad.Trans.Class (lift, MonadTrans)
import Data.Functor (($>))
import Data.Functor.Identity (Identity(..))
import Fusion.Plugin.Types (Fuse(..))
import GHC.Base (build)
import GHC.Types (SPEC(..))
import Prelude hiding (map, mapM, foldr, take, concatMap, takeWhile)

import Streamly.Internal.Data.Fold.Type (Fold(..))
import Streamly.Internal.Data.Refold.Type (Refold(..))
import Streamly.Internal.Data.Stream.StreamD.Step (Step (..))
import Streamly.Internal.Data.SVar.Type (State, adaptState, defState)
import Streamly.Internal.Data.Unfold.Type (Unfold(..))

import qualified Streamly.Internal.Data.Fold.Type as FL
import qualified Streamly.Internal.Data.Stream.StreamK.Type as K
#ifdef USE_UNFOLDS_EVERYWHERE
import qualified Streamly.Internal.Data.Unfold.Type as Unfold
#endif

------------------------------------------------------------------------------
-- The direct style stream type
------------------------------------------------------------------------------

-- gst = global state
-- | A stream consists of a step function that generates the next step given a
-- current state, and the current state.
data Stream m a =
    forall s. UnStream (State K.Stream m a -> s -> m (Step s a)) s

-- XXX This causes perf trouble when pattern matching with "Stream"  in a
-- recursive way, e.g. in uncons, foldBreak, concatMap. We need to get rid of
-- this.
unShare :: Stream m a -> Stream m a
unShare (UnStream step state) = UnStream step' state
    where step' gst = step (adaptState gst)

pattern Stream :: (State K.Stream m a -> s -> m (Step s a)) -> s -> Stream m a
pattern Stream step state <- (unShare -> UnStream step state)
    where Stream = UnStream

{-# COMPLETE Stream #-}

------------------------------------------------------------------------------
-- Primitives
------------------------------------------------------------------------------

-- | An empty 'Stream' with a side effect.
{-# INLINE_NORMAL nilM #-}
nilM :: Applicative m => m b -> Stream m a
nilM m = Stream (\_ _ -> m $> Stop) ()

{-# INLINE_NORMAL consM #-}
consM :: Applicative m => m a -> Stream m a -> Stream m a
consM m (Stream step state) = Stream step1 Nothing

    where

    {-# INLINE_LATE step1 #-}
    step1 _ Nothing = (`Yield` Just state) <$> m
    step1 gst (Just st) = do
          (\case
            Yield a s -> Yield a (Just s)
            Skip  s   -> Skip (Just s)
            Stop      -> Stop) <$> step gst st

-- | Does not fuse, has the same performance as the StreamK version.
{-# INLINE_NORMAL uncons #-}
uncons :: Monad m => Stream m a -> m (Maybe (a, Stream m a))
uncons (UnStream step state) = go SPEC state
  where
    go !_ st = do
        r <- step defState st
        case r of
            Yield x s -> return $ Just (x, Stream step s)
            Skip  s   -> go SPEC s
            Stop      -> return Nothing

------------------------------------------------------------------------------
-- From 'Unfold'
------------------------------------------------------------------------------

data UnfoldState s = UnfoldNothing | UnfoldJust s

-- | Convert an 'Unfold' into a 'Stream' by supplying it a seed.
--
{-# INLINE_NORMAL unfold #-}
unfold :: Applicative m => Unfold m a b -> a -> Stream m b
unfold (Unfold ustep inject) seed = Stream step UnfoldNothing

    where

    {-# INLINE_LATE step #-}
    step _ UnfoldNothing = Skip . UnfoldJust <$> inject seed
    step _ (UnfoldJust st) = do
        (\case
            Yield x s -> Yield x (UnfoldJust s)
            Skip s    -> Skip (UnfoldJust s)
            Stop      -> Stop) <$> ustep st

------------------------------------------------------------------------------
-- From Values
------------------------------------------------------------------------------

-- | Create a singleton 'Stream' from a pure value.
{-# INLINE_NORMAL fromPure #-}
fromPure :: Applicative m => a -> Stream m a
fromPure x = Stream (\_ s -> pure $ step undefined s) True
  where
    {-# INLINE_LATE step #-}
    step _ True  = Yield x False
    step _ False = Stop

-- | Create a singleton 'Stream' from a monadic action.
{-# INLINE_NORMAL fromEffect #-}
fromEffect :: Applicative m => m a -> Stream m a
fromEffect m = Stream step True

    where

    {-# INLINE_LATE step #-}
    step _ True  = (`Yield` False) <$> m
    step _ False = pure Stop

------------------------------------------------------------------------------
-- From Containers
------------------------------------------------------------------------------

-- Adapted from the vector package.
-- | Convert a list of pure values to a 'Stream'
{-# INLINE_LATE fromList #-}
fromList :: Applicative m => [a] -> Stream m a
#ifdef USE_UNFOLDS_EVERYWHERE
fromList = unfold Unfold.fromList
#else
fromList = Stream step
  where
    {-# INLINE_LATE step #-}
    step _ (x:xs) = pure $ Yield x xs
    step _ []     = pure Stop
#endif

------------------------------------------------------------------------------
-- Conversions From/To
------------------------------------------------------------------------------

-- | Convert a CPS encoded StreamK to direct style step encoded StreamD
{-# INLINE_LATE fromStreamK #-}
fromStreamK :: Applicative m => K.Stream m a -> Stream m a
fromStreamK = Stream step
    where
    step gst m1 =
        let stop       = pure Stop
            single a   = pure $ Yield a K.nil
            yieldk a r = pure $ Yield a r
         in K.foldStreamShared gst yieldk single stop m1

-- | Convert a direct style step encoded StreamD to a CPS encoded StreamK
{-# INLINE_LATE toStreamK #-}
toStreamK :: Monad m => Stream m a -> K.Stream m a
toStreamK (Stream step state) = go state
    where
    go st = K.MkStream $ \gst yld _ stp ->
      let go' ss = do
           r <- step gst ss
           case r of
               Yield x s -> yld x (go s)
               Skip  s   -> go' s
               Stop      -> stp
      in go' st

#ifndef DISABLE_FUSION
{-# RULES "fromStreamK/toStreamK fusion"
    forall s. toStreamK (fromStreamK s) = s #-}
{-# RULES "toStreamK/fromStreamK fusion"
    forall s. fromStreamK (toStreamK s) = s #-}
#endif

------------------------------------------------------------------------------
-- Running a 'Fold'
------------------------------------------------------------------------------

{-# INLINE_NORMAL fold #-}
fold :: Monad m => Fold m a b -> Stream m a -> m b
fold fld strm = do
    (b, _) <- foldBreak fld strm
    return b

{-# INLINE_NORMAL foldEither #-}
foldEither :: Monad m =>
    Fold m a b -> Stream m a -> m (Either (Fold m a b) (b, Stream m a))
foldEither (Fold fstep begin done) (UnStream step state) = do
    res <- begin
    case res of
        FL.Partial fs -> go SPEC fs state
        FL.Done fb -> return $! Right (fb, Stream step state)

    where

    {-# INLINE go #-}
    go !_ !fs st = do
        r <- step defState st
        case r of
            Yield x s -> do
                res <- fstep fs x
                case res of
                    FL.Done b -> return $! Right (b, Stream step s)
                    FL.Partial fs1 -> go SPEC fs1 s
            Skip s -> go SPEC fs s
            Stop -> return $! Left (Fold fstep (return $ FL.Partial fs) done)

{-# INLINE_NORMAL foldBreak #-}
foldBreak :: Monad m => Fold m a b -> Stream m a -> m (b, Stream m a)
foldBreak fld strm = do
    r <- foldEither fld strm
    case r of
        Right res -> return res
        Left (Fold _ initial extract) -> do
            res <- initial
            case res of
                FL.Done _ -> error "foldBreak: unreachable state"
                FL.Partial s -> do
                    b <- extract s
                    return (b, nil)

    where

    nil = Stream (\_ _ -> return Stop) ()

{-# INLINE_NORMAL foldContinue #-}
foldContinue :: Monad m => Fold m a b -> Stream m a -> Fold m a b
foldContinue (Fold fstep finitial fextract) (Stream sstep state) =
    Fold fstep initial fextract

    where

    initial = do
        res <- finitial
        case res of
            FL.Partial fs -> go SPEC fs state
            FL.Done fb -> return $ FL.Done fb

    {-# INLINE go #-}
    go !_ !fs st = do
        r <- sstep defState st
        case r of
            Yield x s -> do
                res <- fstep fs x
                case res of
                    FL.Done b -> return $ FL.Done b
                    FL.Partial fs1 -> go SPEC fs1 s
            Skip s -> go SPEC fs s
            Stop -> return $ FL.Partial fs

------------------------------------------------------------------------------
-- Right Folds
------------------------------------------------------------------------------

-- Adapted from the vector package.
--
-- XXX Use of SPEC constructor in folds causes 2x performance degradation in
-- one shot operations, but helps immensely in operations composed of multiple
-- combinators or the same combinator many times. There seems to be an
-- opportunity to optimize here, can we get both, better perf for single ops
-- as well as composed ops? Without SPEC, all single operation benchmarks
-- become 2x faster.

-- The way we want a left fold to be strict, dually we want the right fold to
-- be lazy.  The correct signature of the fold function to keep it lazy must be
-- (a -> m b -> m b) instead of (a -> b -> m b). We were using the latter
-- earlier, which is incorrect. In the latter signature we have to feed the
-- value to the fold function after evaluating the monadic action, depending on
-- the bind behavior of the monad, the action may get evaluated immediately
-- introducing unnecessary strictness to the fold. If the implementation is
-- lazy the following example, must work:
--
-- S.foldrM (\x t -> if x then return t else return False) (return True)
--  (S.fromList [False,undefined] :: Stream IO Bool)
--
{-# INLINE_NORMAL foldrM #-}
foldrM :: Monad m => (a -> m b -> m b) -> m b -> Stream m a -> m b
foldrM f z (Stream step state) = go SPEC state
  where
    {-# INLINE_LATE go #-}
    go !_ st = do
          r <- step defState st
          case r of
            Yield x s -> f x (go SPEC s)
            Skip s    -> go SPEC s
            Stop      -> z

{-# INLINE_NORMAL foldrMx #-}
foldrMx :: Monad m
    => (a -> m x -> m x) -> m x -> (m x -> m b) -> Stream m a -> m b
foldrMx fstep final convert (Stream step state) = convert $ go SPEC state
  where
    {-# INLINE_LATE go #-}
    go !_ st = do
          r <- step defState st
          case r of
            Yield x s -> fstep x (go SPEC s)
            Skip s    -> go SPEC s
            Stop      -> final

-- XXX Should we make all argument strict wherever we use SPEC?

-- Note that foldr works on pure values, therefore it becomes necessarily
-- strict when the monad m is strict. In that case it cannot terminate early,
-- it would evaluate all of its input.  Though, this should work fine with lazy
-- monads. For example, if "any" is implemented using "foldr" instead of
-- "foldrM" it performs the same with Identity monad but performs 1000x slower
-- with IO monad.
--
{-# INLINE_NORMAL foldr #-}
foldr :: Monad m => (a -> b -> b) -> b -> Stream m a -> m b
foldr f z = foldrM (liftA2 f . return) (return z)

-- this performs horribly, should not be used
{-# INLINE_NORMAL foldrS #-}
foldrS
    :: Monad m
    => (a -> Stream m b -> Stream m b)
    -> Stream m b
    -> Stream m a
    -> Stream m b
foldrS f final (Stream step state) = go SPEC state
  where
    {-# INLINE_LATE go #-}
    go !_ st = do
        -- defState??
        r <- fromEffect $ step defState st
        case r of
          Yield x s -> f x (go SPEC s)
          Skip s    -> go SPEC s
          Stop      -> final

------------------------------------------------------------------------------
-- Left Folds
------------------------------------------------------------------------------

-- XXX run begin action only if the stream is not empty.
{-# INLINE_NORMAL foldlMx' #-}
foldlMx' :: Monad m => (x -> a -> m x) -> m x -> (x -> m b) -> Stream m a -> m b
foldlMx' fstep begin done (Stream step state) =
    begin >>= \x -> go SPEC x state
  where
    -- XXX !acc?
    {-# INLINE_LATE go #-}
    go !_ acc st = acc `seq` do
        r <- step defState st
        case r of
            Yield x s -> do
                acc' <- fstep acc x
                go SPEC acc' s
            Skip s -> go SPEC acc s
            Stop   -> done acc

{-# INLINE foldlx' #-}
foldlx' :: Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream m a -> m b
foldlx' fstep begin done =
    foldlMx' (\b a -> return (fstep b a)) (return begin) (return . done)

-- Adapted from the vector package.
-- XXX implement in terms of foldlMx'?
{-# INLINE_NORMAL foldlM' #-}
foldlM' :: Monad m => (b -> a -> m b) -> m b -> Stream m a -> m b
foldlM' fstep mbegin (Stream step state) = do
    begin <- mbegin
    go SPEC begin state
  where
    {-# INLINE_LATE go #-}
    go !_ acc st = acc `seq` do
        r <- step defState st
        case r of
            Yield x s -> do
                acc' <- fstep acc x
                go SPEC acc' s
            Skip s -> go SPEC acc s
            Stop   -> return acc

{-# INLINE foldl' #-}
foldl' :: Monad m => (b -> a -> b) -> b -> Stream m a -> m b
foldl' fstep begin = foldlM' (\b a -> return (fstep b a)) (return begin)

------------------------------------------------------------------------------
-- Special folds
------------------------------------------------------------------------------

-- | Run a streaming composition, discard the results.
{-# INLINE_LATE drain #-}
drain :: Monad m => Stream m a -> m ()
-- drain = foldrM (\_ xs -> xs) (return ())
drain (Stream step state) = go SPEC state
  where
    go !_ st = do
        r <- step defState st
        case r of
            Yield _ s -> go SPEC s
            Skip s    -> go SPEC s
            Stop      -> return ()

------------------------------------------------------------------------------
-- To Containers
------------------------------------------------------------------------------

{-# INLINE_NORMAL toList #-}
toList :: Monad m => Stream m a -> m [a]
toList = foldr (:) []

-- Use foldr/build fusion to fuse with list consumers
-- This can be useful when using the IsList instance
{-# INLINE_LATE toListFB #-}
toListFB :: (a -> b -> b) -> b -> Stream Identity a -> b
toListFB c n (Stream step state) = go state
  where
    go st = case runIdentity (step defState st) of
             Yield x s -> x `c` go s
             Skip s    -> go s
             Stop      -> n

{-# RULES "toList Identity" toList = toListId #-}
{-# INLINE_EARLY toListId #-}
toListId :: Stream Identity a -> Identity [a]
toListId s = Identity $ build (\c n -> toListFB c n s)

------------------------------------------------------------------------------
-- Multi-stream folds
------------------------------------------------------------------------------

-- Adapted from the vector package.
{-# INLINE_NORMAL eqBy #-}
eqBy :: Monad m => (a -> b -> Bool) -> Stream m a -> Stream m b -> m Bool
eqBy eq (Stream step1 t1) (Stream step2 t2) = eq_loop0 SPEC t1 t2
  where
    eq_loop0 !_ s1 s2 = do
      r <- step1 defState s1
      case r of
        Yield x s1' -> eq_loop1 SPEC x s1' s2
        Skip    s1' -> eq_loop0 SPEC   s1' s2
        Stop        -> eq_null s2

    eq_loop1 !_ x s1 s2 = do
      r <- step2 defState s2
      case r of
        Yield y s2'
          | eq x y    -> eq_loop0 SPEC   s1 s2'
          | otherwise -> return False
        Skip    s2'   -> eq_loop1 SPEC x s1 s2'
        Stop          -> return False

    eq_null s2 = do
      r <- step2 defState s2
      case r of
        Yield _ _ -> return False
        Skip s2'  -> eq_null s2'
        Stop      -> return True

-- Adapted from the vector package.
-- | Compare two streams lexicographically
{-# INLINE_NORMAL cmpBy #-}
cmpBy
    :: Monad m
    => (a -> b -> Ordering) -> Stream m a -> Stream m b -> m Ordering
cmpBy cmp (Stream step1 t1) (Stream step2 t2) = cmp_loop0 SPEC t1 t2
  where
    cmp_loop0 !_ s1 s2 = do
      r <- step1 defState s1
      case r of
        Yield x s1' -> cmp_loop1 SPEC x s1' s2
        Skip    s1' -> cmp_loop0 SPEC   s1' s2
        Stop        -> cmp_null s2

    cmp_loop1 !_ x s1 s2 = do
      r <- step2 defState s2
      case r of
        Yield y s2' -> case x `cmp` y of
                         EQ -> cmp_loop0 SPEC s1 s2'
                         c  -> return c
        Skip    s2' -> cmp_loop1 SPEC x s1 s2'
        Stop        -> return GT

    cmp_null s2 = do
      r <- step2 defState s2
      case r of
        Yield _ _ -> return LT
        Skip s2'  -> cmp_null s2'
        Stop      -> return EQ

------------------------------------------------------------------------------
-- Transformations
------------------------------------------------------------------------------

-- Adapted from the vector package.
-- | Map a monadic function over a 'Stream'
{-# INLINE_NORMAL mapM #-}
mapM :: Monad m => (a -> m b) -> Stream m a -> Stream m b
mapM f (Stream step state) = Stream step' state
  where
    {-# INLINE_LATE step' #-}
    step' gst st = do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> f x >>= \a -> return $ Yield a s
            Skip s    -> return $ Skip s
            Stop      -> return Stop

{-# INLINE map #-}
map :: Monad m => (a -> b) -> Stream m a -> Stream m b
map f = mapM (return . f)

instance Functor m => Functor (Stream m) where
    {-# INLINE fmap #-}
    fmap f (Stream step state) = Stream step' state
      where
        {-# INLINE_LATE step' #-}
        step' gst st = fmap (fmap f) (step (adaptState gst) st)

    {-# INLINE (<$) #-}
    (<$) = fmap . const

-------------------------------------------------------------------------------
-- Filtering
-------------------------------------------------------------------------------

-- Adapted from the vector package.
{-# INLINE_NORMAL take #-}
take :: Applicative m => Int -> Stream m a -> Stream m a
take n (Stream step state) = n `seq` Stream step' (state, 0)

    where

    {-# INLINE_LATE step' #-}
    step' gst (st, i) | i < n = do
        (\case
            Yield x s -> Yield x (s, i + 1)
            Skip s    -> Skip (s, i)
            Stop      -> Stop) <$> step gst st
    step' _ (_, _) = pure Stop

-- Adapted from the vector package.
{-# INLINE_NORMAL takeWhileM #-}
takeWhileM :: Monad m => (a -> m Bool) -> Stream m a -> Stream m a
takeWhileM f (Stream step state) = Stream step' state
  where
    {-# INLINE_LATE step' #-}
    step' gst st = do
        r <- step gst st
        case r of
            Yield x s -> do
                b <- f x
                return $ if b then Yield x s else Stop
            Skip s -> return $ Skip s
            Stop   -> return Stop

{-# INLINE takeWhile #-}
takeWhile :: Monad m => (a -> Bool) -> Stream m a -> Stream m a
takeWhile f = takeWhileM (return . f)

-- Like takeWhile but with an inverted condition and also taking
-- the matching element.

{-# INLINE_NORMAL takeEndByM #-}
takeEndByM :: Monad m => (a -> m Bool) -> Stream m a -> Stream m a
takeEndByM f (Stream step state) = Stream step' (Just state)
  where
    {-# INLINE_LATE step' #-}
    step' gst (Just st) = do
        r <- step gst st
        case r of
            Yield x s -> do
                b <- f x
                return $
                    if not b
                    then Yield x (Just s)
                    else Yield x Nothing
            Skip s -> return $ Skip (Just s)
            Stop   -> return Stop

    step' _ Nothing = return Stop

{-# INLINE takeEndBy #-}
takeEndBy :: Monad m => (a -> Bool) -> Stream m a -> Stream m a
takeEndBy f = takeEndByM (return . f)

------------------------------------------------------------------------------
-- Combine N Streams - concatAp
------------------------------------------------------------------------------

{-# INLINE_NORMAL concatAp #-}
concatAp :: Functor f => Stream f (a -> b) -> Stream f a -> Stream f b
concatAp (Stream stepa statea) (Stream stepb stateb) =
    Stream step' (Left statea)

    where

    {-# INLINE_LATE step' #-}
    step' gst (Left st) = fmap
        (\case
            Yield f s -> Skip (Right (f, s, stateb))
            Skip    s -> Skip (Left s)
            Stop      -> Stop)
        (stepa (adaptState gst) st)
    step' gst (Right (f, os, st)) = fmap
        (\case
            Yield a s -> Yield (f a) (Right (f, os, s))
            Skip s    -> Skip (Right (f,os, s))
            Stop      -> Skip (Left os))
        (stepb (adaptState gst) st)

{-# INLINE_NORMAL apSequence #-}
apSequence :: Functor f => Stream f a -> Stream f b -> Stream f b
apSequence (Stream stepa statea) (Stream stepb stateb) =
    Stream step (Left statea)

    where

    {-# INLINE_LATE step #-}
    step gst (Left st) =
        fmap
            (\case
                 Yield _ s -> Skip (Right (s, stateb))
                 Skip s -> Skip (Left s)
                 Stop -> Stop)
            (stepa (adaptState gst) st)
    step gst (Right (ostate, st)) =
        fmap
            (\case
                 Yield b s -> Yield b (Right (ostate, s))
                 Skip s -> Skip (Right (ostate, s))
                 Stop -> Skip (Left ostate))
            (stepb gst st)

{-# INLINE_NORMAL apDiscardSnd #-}
apDiscardSnd :: Functor f => Stream f a -> Stream f b -> Stream f a
apDiscardSnd (Stream stepa statea) (Stream stepb stateb) =
    Stream step (Left statea)

    where

    {-# INLINE_LATE step #-}
    step gst (Left st) =
        fmap
            (\case
                 Yield b s -> Skip (Right (s, stateb, b))
                 Skip s -> Skip (Left s)
                 Stop -> Stop)
            (stepa gst st)
    step gst (Right (ostate, st, b)) =
        fmap
            (\case
                 Yield _ s -> Yield b (Right (ostate, s, b))
                 Skip s -> Skip (Right (ostate, s, b))
                 Stop -> Skip (Left ostate))
            (stepb (adaptState gst) st)

instance Applicative f => Applicative (Stream f) where
    {-# INLINE pure #-}
    pure = fromPure

    {-# INLINE (<*>) #-}
    (<*>) = concatAp

    {-# INLINE liftA2 #-}
    liftA2 f x = (<*>) (fmap f x)

    {-# INLINE (*>) #-}
    (*>) = apSequence

    {-# INLINE (<*) #-}
    (<*) = apDiscardSnd

------------------------------------------------------------------------------
-- Combine N Streams - unfoldMany
------------------------------------------------------------------------------

{-# ANN type ConcatMapUState Fuse #-}
data ConcatMapUState o i =
      ConcatMapUOuter o
    | ConcatMapUInner o i

-- | @unfoldMany unfold stream@ uses @unfold@ to map the input stream elements
-- to streams and then flattens the generated streams into a single output
-- stream.

-- This is like 'concatMap' but uses an unfold with an explicit state to
-- generate the stream instead of a 'Stream' type generator. This allows better
-- optimization via fusion.  This can be many times more efficient than
-- 'concatMap'.

{-# INLINE_NORMAL unfoldMany #-}
unfoldMany :: Monad m => Unfold m a b -> Stream m a -> Stream m b
unfoldMany (Unfold istep inject) (Stream ostep ost) =
    Stream step (ConcatMapUOuter ost)
  where
    {-# INLINE_LATE step #-}
    step gst (ConcatMapUOuter o) = do
        r <- ostep (adaptState gst) o
        case r of
            Yield a o' -> do
                i <- inject a
                i `seq` return (Skip (ConcatMapUInner o' i))
            Skip o' -> return $ Skip (ConcatMapUOuter o')
            Stop -> return Stop

    step _ (ConcatMapUInner o i) = do
        r <- istep i
        return $ case r of
            Yield x i' -> Yield x (ConcatMapUInner o i')
            Skip i'    -> Skip (ConcatMapUInner o i')
            Stop       -> Skip (ConcatMapUOuter o)

------------------------------------------------------------------------------
-- Combine N Streams - concatMap
------------------------------------------------------------------------------

-- Adapted from the vector package.
{-# INLINE_NORMAL concatMapM #-}
concatMapM :: Monad m => (a -> m (Stream m b)) -> Stream m a -> Stream m b
concatMapM f (Stream step state) = Stream step' (Left state)
  where
    {-# INLINE_LATE step' #-}
    step' gst (Left st) = do
        r <- step (adaptState gst) st
        case r of
            Yield a s -> do
                b_stream <- f a
                return $ Skip (Right (b_stream, s))
            Skip s -> return $ Skip (Left s)
            Stop -> return Stop

    -- XXX flattenArrays is 5x faster than "concatMap fromArray". if somehow we
    -- can get inner_step to inline and fuse here we can perhaps get the same
    -- performance using "concatMap fromArray".
    --
    -- XXX using the pattern synonym "Stream" causes a major performance issue
    -- here even if the synonym does not include an adaptState call. Need to
    -- find out why. Is that something to be fixed in GHC?
    step' gst (Right (UnStream inner_step inner_st, st)) = do
        r <- inner_step (adaptState gst) inner_st
        case r of
            Yield b inner_s ->
                return $ Yield b (Right (Stream inner_step inner_s, st))
            Skip inner_s ->
                return $ Skip (Right (Stream inner_step inner_s, st))
            Stop -> return $ Skip (Left st)

{-# INLINE concatMap #-}
concatMap :: Monad m => (a -> Stream m b) -> Stream m a -> Stream m b
concatMap f = concatMapM (return . f)

-- XXX The idea behind this rule is to rewrite any calls to "concatMap
-- fromArray" automatically to flattenArrays which is much faster.  However, we
-- need an INLINE_EARLY on concatMap for this rule to fire. But if we use
-- INLINE_EARLY on concatMap or fromArray then direct uses of
-- "concatMap fromArray" (without the RULE) become much slower, this means
-- "concatMap f" in general would become slower. Need to find a solution to
-- this.
--
-- {-# RULES "concatMap Array.toStreamD"
--      concatMap Array.toStreamD = Array.flattenArray #-}

-- NOTE: even though concatMap for StreamD is 4x faster compared to StreamK,
-- the monad instance does not seem to be significantly faster.
instance Monad m => Monad (Stream m) where
    {-# INLINE return #-}
    return = pure

    {-# INLINE (>>=) #-}
    (>>=) = flip concatMap

    {-# INLINE (>>) #-}
    (>>) = (*>)

------------------------------------------------------------------------------
-- Grouping/Splitting
------------------------------------------------------------------------------

-- s = stream state, fs = fold state
{-# ANN type FoldManyPost Fuse #-}
data FoldManyPost s fs b a
    = FoldManyPostStart s
    | FoldManyPostLoop s fs
    | FoldManyPostYield b (FoldManyPost s fs b a)
    | FoldManyPostDone

-- | 'Streamly.Internal.Data.Stream.foldManyPost'.
{-# INLINE_NORMAL foldManyPost #-}
foldManyPost :: Monad m => Fold m a b -> Stream m a -> Stream m b
foldManyPost (Fold fstep initial extract) (Stream step state) =
    Stream step' (FoldManyPostStart state)

    where

    {-# INLINE consume #-}
    consume x s fs = do
        res <- fstep fs x
        return
            $ Skip
            $ case res of
                  FL.Done b -> FoldManyPostYield b (FoldManyPostStart s)
                  FL.Partial ps -> FoldManyPostLoop s ps

    {-# INLINE_LATE step' #-}
    step' _ (FoldManyPostStart st) = do
        r <- initial
        return
            $ Skip
            $ case r of
                  FL.Done b -> FoldManyPostYield b (FoldManyPostStart st)
                  FL.Partial fs -> FoldManyPostLoop st fs
    step' gst (FoldManyPostLoop st fs) = do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> consume x s fs
            Skip s -> return $ Skip (FoldManyPostLoop s fs)
            Stop -> do
                b <- extract fs
                return $ Skip (FoldManyPostYield b FoldManyPostDone)
    step' _ (FoldManyPostYield b next) = return $ Yield b next
    step' _ FoldManyPostDone = return Stop

{-# ANN type FoldMany Fuse #-}
data FoldMany s fs b a
    = FoldManyStart s
    | FoldManyFirst a s
    | FoldManyLoop s fs
    | FoldManyYield b (FoldMany s fs b a)
    | FoldManyDone

-- XXX Nested foldMany does not fuse.

-- | 'Streamly.Internal.Data.Stream.foldMany'.
{-# INLINE_NORMAL foldMany #-}
foldMany :: Monad m => Fold m a b -> Stream m a -> Stream m b
foldMany (Fold fstep initial extract) (Stream step state) =
    Stream step' (FoldManyStart state)

    where

    {-# INLINE consume #-}
    consume x s fs = do
        res <- fstep fs x
        return
            $ Skip
            $ case res of
                  FL.Done b -> FoldManyYield b (FoldManyStart s)
                  FL.Partial ps -> FoldManyLoop s ps

    {-# INLINE_LATE step' #-}
    step' gst (FoldManyStart st) = do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> return $ Skip (FoldManyFirst x s)
            Skip s -> return $ Skip (FoldManyStart s)
            Stop -> return Stop
    step' _ (FoldManyFirst x st) = do
        r <- initial
        case r of
            FL.Done b -> return $ Skip $ FoldManyYield b (FoldManyFirst x st)
            FL.Partial fs -> consume x st fs
    step' gst (FoldManyLoop st fs) = do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> consume x s fs
            Skip s -> return $ Skip (FoldManyLoop s fs)
            Stop -> do
                b <- extract fs
                return $ Skip (FoldManyYield b FoldManyDone)
    step' _ (FoldManyYield b next) = return $ Yield b next
    step' _ FoldManyDone = return Stop

{-# INLINE chunksOf #-}
chunksOf :: Monad m => Int -> Fold m a b -> Stream m a -> Stream m b
chunksOf n f = foldMany (FL.take n f)

-- Keep the argument order consistent with refoldIterateM.

-- | Like 'foldMany' but for the 'Refold' type.  The supplied action is used as
-- the initial value for each refold.
--
-- /Internal/
{-# INLINE_NORMAL refoldMany #-}
refoldMany :: Monad m => Refold m x a b -> m x -> Stream m a -> Stream m b
refoldMany (Refold fstep inject extract) action (Stream step state) =
    Stream step' (FoldManyStart state)

    where

    {-# INLINE consume #-}
    consume x s fs = do
        res <- fstep fs x
        return
            $ Skip
            $ case res of
                  FL.Done b -> FoldManyYield b (FoldManyStart s)
                  FL.Partial ps -> FoldManyLoop s ps

    {-# INLINE_LATE step' #-}
    step' gst (FoldManyStart st) = do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> return $ Skip (FoldManyFirst x s)
            Skip s -> return $ Skip (FoldManyStart s)
            Stop -> return Stop
    step' _ (FoldManyFirst x st) = do
        r <- action >>= inject
        case r of
            FL.Done b -> return $ Skip $ FoldManyYield b (FoldManyFirst x st)
            FL.Partial fs -> consume x st fs
    step' gst (FoldManyLoop st fs) = do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> consume x s fs
            Skip s -> return $ Skip (FoldManyLoop s fs)
            Stop -> do
                b <- extract fs
                return $ Skip (FoldManyYield b FoldManyDone)
    step' _ (FoldManyYield b next) = return $ Yield b next
    step' _ FoldManyDone = return Stop

------------------------------------------------------------------------------
-- Other instances
------------------------------------------------------------------------------

instance MonadTrans Stream where
    {-# INLINE lift #-}
    lift = fromEffect

instance (MonadThrow m) => MonadThrow (Stream m) where
    throwM = lift . throwM
