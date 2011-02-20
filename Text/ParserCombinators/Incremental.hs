{- 
    Copyright 2010-2011 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

-- | This module defines incremental parser. The exported 'Parser' type can provide partially constructed results at any
-- point during the parse.
-- 
-- Implementation is based on Brzozowski derivatives.

{-# LANGUAGE ScopedTypeVariables, Rank2Types, ExistentialQuantification #-}

module Text.ParserCombinators.Incremental
   (
    -- * The Parser type
    Parser, 
    -- * Using a Parser
    feed, feedEof, feedAll, feedListPrefix, feedLongestPrefix, feedShortestPrefix, results, resultPrefix,
    -- * Parser primitives
    empty, eof, anyToken, token, satisfy, count, acceptAll, string, prefixOf, whilePrefixOf, while, while1,
    skip, optional, optionMaybe, many, many0, many1, manyTill,
    -- * Parser combinators
    pmap, (><), (>><), (<<|>), lookAhead, lookAheadNot, longest, and, andThen,
    -- * Utilities
    showWithDefault
   )
where

import Prelude hiding (and, foldl)
import Control.Applicative (Applicative (pure, (<*>)), Alternative (empty, (<|>), some, many))
import Control.Monad (Functor (fmap), Monad (return, (>>=), (>>)), MonadPlus (mzero, mplus), liftM2)
import Data.Maybe (fromMaybe)
import Data.Monoid (Monoid, mempty, mappend)
import Data.Foldable (Foldable, foldl, toList)

-- | This is a cofunctor data type for selecting a prefix of an input stream. If the next input item is acceptable, the
-- ticker function returns the ticker for the rest of the stream. If not, it returns 'Nothing'.
data Parser s r = Failure
                | Result (InputTail s) r
                | ResultPart (r -> r) (Parser s r)
                | Choice (Parser s r) (Parser s r)
                | CommitedLeftChoice (Parser s r) (Parser s r)
                | More (s -> Parser s r)
                | LookAhead (Parser s r) (Parser s r -> Parser s r)
                | forall r'. LookAheadIgnore (Parser s r') (Parser s r' -> Parser s r)

type InputTail s = [s] -> [s]

feed :: s -> Parser s r -> Parser s r
feed _ Failure = Failure
feed x (Result t r) = Result (t . (x:)) r
feed x (ResultPart r p) = resultPart r (feed x p)
feed x (Choice p1 p2) = feed x p1 <|> feed x p2
feed x (CommitedLeftChoice p1 p2) = feed x p1 <<|> feed x p2
feed x (More f) = f x
feed x (LookAhead p c) = lookAheadInto (feed x p) (feed x . c)
feed x (LookAheadIgnore p c) = lookAheadIgnore (feed x p) (feed x . c)

feedEof :: Parser s r -> Parser s r
feedEof Failure = Failure
feedEof p@Result{} = p
feedEof (ResultPart r p) = prepend r (feedEof p)
   where prepend r (Result t r') = Result t (r r')
         prepend r (Choice p1 p2) = Choice (prepend r p1) (prepend r p2)
         prepend r Failure = Failure
feedEof (Choice p1 p2) = feedEof p1 <|> feedEof p2
feedEof (CommitedLeftChoice p1 p2) = feedEof p1 <<|> feedEof p2
feedEof More{} = Failure
feedEof (LookAhead p c) = lookAheadInto (feedEof p) (feedEof . c)
feedEof (LookAheadIgnore p c) = lookAheadIgnore (feedEof p) (feedEof . c)

feedList :: [s] -> Parser s r -> Parser s r
feedList s p = foldl (flip feed) p s

feedAll :: Foldable f => f s -> Parser s r -> Parser s r
feedAll s p = foldl (flip feed) p s

feedShortestPrefix :: Foldable f => f s -> Parser s r -> ([s], Parser s r)
feedShortestPrefix s p = case foldl feedOrStore (Nothing, p) s
                         of (Nothing, p') -> ([], p')
                            (Just f, p') -> (f [], p')
   where feedOrStore :: (Maybe ([s] -> [s]), Parser s r) -> s -> (Maybe ([s] -> [s]), Parser s r)
         feedOrStore (Nothing, p) x = if null (results p) then (Nothing, feed x p) else (Just (x :), p)
         feedOrStore (Just store, p) x = (Just (store . (x :)), p)

feedLongestPrefix :: (Foldable f, Monoid r) => f s -> Parser s r -> (Parser s r, [s])
feedLongestPrefix s p = case feedEof $ feedAll s $ duplicate p
                        of Failure -> (Failure, toList s)
                           Result t r -> (r, t [])

feedListPrefix :: [s] -> [s] -> Parser s r -> (Parser s r, [s])
feedListPrefix whole chunk p = feedRest chunk p
   where feedRest rest (Result t r) = (Result id r, t rest)
         feedRest _ Failure = (Failure, whole)
         feedRest [] p = (p, [])
         feedRest (x:xs) p = feedRest xs (feed x p)

results :: Parser s r -> [(r, [s] -> [s])]
results (Result t r) = [(r, t)]
results (ResultPart f p) = map (\(r, t)-> (f r, t)) (results p)
results (Choice p1@Result{} p2) = results p1 ++ results p2
results _ = []

hasResult :: Parser s r -> Bool
hasResult Result{} = True
hasResult (ResultPart _ p) = hasResult p
hasResult (Choice Result{} _) = True
hasResult (CommitedLeftChoice _ p) = hasResult p
hasResult _ = False

resultPrefix :: Monoid r => Parser s r -> (Maybe r, Parser s r)
resultPrefix (Result t r) = (Just r, Result t mempty)
resultPrefix (ResultPart f p) = (Just (f $ fromMaybe mempty r), p')
   where (r, p') = resultPrefix p
resultPrefix p = (Nothing, p)

partialResults :: Monoid r => Parser s r -> [(r, Parser s r)]
partialResults p = collect p [(mempty, p)]
   where collect (ResultPart f p) rest = [(f r, p') | (r, p') <- partialResults p] ++ rest
         collect (Choice p1 p2) rest = collect p1 (collect p2 rest)
         collect (CommitedLeftChoice p1 p2) rest = case collect p1 [] of [] -> collect p2 rest
                                                                         r -> r ++ rest
         collect p rest = rest

lookAhead :: Parser s r -> Parser s r
lookAhead p = lookAheadInto p id

lookAheadNot :: Monoid r => Parser s r' -> Parser s r
lookAheadNot = lookAheadNotInto mempty

lookAheadNotInto :: Parser s r -> Parser s r' -> Parser s r
lookAheadNotInto p' p = lookAheadIgnore p c
   where c Failure = p'
         c _ = Failure

lookAheadInto :: Parser s r -> (Parser s r -> Parser s r) -> Parser s r
lookAheadInto Failure c                = Failure
lookAheadInto (Result _ r) c           = c (Result id r)
lookAheadInto (ResultPart r p) c       = resultPart r (lookAheadInto p c)
lookAheadInto (LookAhead p c') c       = LookAhead p (c . c')
lookAheadInto (LookAheadIgnore p c') c = LookAheadIgnore p (c . c')
lookAheadInto (Choice p1 p2) c         = lookAheadInto p1 c <|> lookAheadInto p2 c
lookAheadInto p c                      = LookAhead p c

lookAheadIgnore :: Parser s r' -> (Parser s r' -> Parser s r) -> Parser s r
lookAheadIgnore Failure c                = c Failure
lookAheadIgnore p@Result{} c             = c p
lookAheadIgnore (ResultPart r p) c       = lookAheadIgnore p c
lookAheadIgnore (LookAhead p c') c       = LookAheadIgnore p (c . c')
lookAheadIgnore (LookAheadIgnore p c') c = LookAheadIgnore p (c . c')
lookAheadIgnore (Choice p1 p2) c         = lookAheadIgnore p1 c <|> lookAheadIgnore p2 c
lookAheadIgnore p c                      = LookAheadIgnore p c

resultPart :: (r -> r) -> Parser s r -> Parser s r
resultPart _ Failure = Failure
resultPart f (Result t r) = Result t (f r)
resultPart f (ResultPart g p) = ResultPart (f . g) p
resultPart f p = ResultPart f p

instance Functor (Parser s) where
   fmap f Failure = Failure
   fmap f (Result t r) = Result t (f r)
   fmap f p@ResultPart{} = resolve (fmap f) p
   fmap f (Choice p1 p2) = Choice (fmap f p1) (fmap f p2)
   fmap f (CommitedLeftChoice p1 p2) = CommitedLeftChoice (fmap f p1) (fmap f p2)
   fmap f (More g) = More (fmap f . g)
   fmap f p@LookAhead{} = resolve (fmap f) p
   fmap f (LookAheadIgnore p c) = LookAheadIgnore p (fmap f . c)

instance Applicative (Parser s) where
   pure = Result id
   Failure <*> _ = Failure
   Result t f <*> p = fmap f (feedList (t []) p)
   Choice p1a p1b <*> p2 = (p1a <*> p2) <|> (p1b <*> p2)
   More f <*> p = More (\x-> f x <*> p)
   p1 <*> p2 = resolve (<*> p2) p1

instance Alternative (Parser s) where
   -- | A parser that succeeds without consuming any input.
   empty = Failure
   
   Failure <|> p = p
   p <|> Failure = p
   More f <|> More g = More (\x-> f x <|> g x)
   p1@Result{} <|> p2 = Choice p1 p2
   p1 <|> p2@Result{} = Choice p2 p1
   Choice p1a@Result{} p1b <|> p2 = Choice p1a (Choice p1b p2)
   p1 <|> Choice p2a@Result{} p2b = Choice p2a (Choice p1 p2b)
   p1 <|> p2 = Choice p1 p2

instance Monad (Parser s) where
   return = Result id

   Failure >>= _ = Failure
   Result t r >>= f = feedList (t []) (f r)
   Choice p1 p2 >>= f = (p1 >>= f) <|> (p2 >>= f)
   More f >>= g = More (\x-> f x >>= g)
   p >>= f = resolve (>>= f) p

   Failure >> _ = Failure
   Result t _ >> p = feedList (t []) p
   ResultPart r p1 >> p2 = p1 >> p2
   Choice p1a p1b >> p2 = (p1a >> p2) <|> (p1b >> p2)
   More f >> p = More (\x-> f x >> p)
   LookAhead p1 c >> p2 = LookAheadIgnore p1 ((>> p2) . c)
   LookAheadIgnore p1 c >> p2 = LookAheadIgnore p1 ((>> p2) . c)
   p1 >> p2 = resolve (>> p2) p1

instance MonadPlus (Parser s) where
   mzero = Failure
   mplus = (<|>)

instance Monoid r => Monoid (Parser s r) where
   mempty = return mempty
   mappend = (><)

-- instance (Monoid s, Monoid r, Show s, Show r) => Show (Parser s r) where
--    show p = showWithDefault mempty p

showWithDefault :: (Monoid r, Show r, Show s) => s -> Parser s r -> String
showWithDefault s Failure = "Failure"
showWithDefault s (Result t r) = "(Result (" ++ shows (t []) ("++) " ++ shows r ")")
showWithDefault s (ResultPart f p) = "(ResultPart (mappend " ++ shows (f mempty) (") " ++ showWithDefault s p ++ ")")
showWithDefault s (Choice p1 p2) = "(Choice " ++ showWithDefault s p1 ++ " " ++ showWithDefault s p2 ++ ")"
showWithDefault s (CommitedLeftChoice p1 p2) =
   "(CommitedLeftChoice " ++ showWithDefault s p1 ++ " " ++ showWithDefault s p2 ++ ")"
showWithDefault s (More f) = "(More $ \\True-> " ++ showWithDefault s (f s) ++ ")"
showWithDefault s (LookAhead p c) = 
   "(LookAhead " ++ showWithDefault s p ++ " " ++ showWithDefault s (c $ feedEof p) ++ ")"
showWithDefault s (LookAheadIgnore p c) = 
   "(LookAheadIgnore " ++ showWithDefault s (fmap (const ()) p) ++ " " ++ showWithDefault s (c $ feedEof p) ++ ")"

resolve :: (Parser s a -> Parser s b) -> Parser s a -> Parser s b
resolve f p@CommitedLeftChoice{} = CommitedLeftChoice (More $ \x-> f (feed x p)) (feedEof $ f $ feedEof p)
resolve f p = Choice (lookAheadNotInto (feedEof p') (More $ const p')) (More $ \x-> f (feed x p))
   where p'= f (feedEof p)

pmap :: (Monoid a, Monoid b) => (a -> b) -> Parser s a -> Parser s b
pmap f Failure = Failure
pmap f (Result t r) = Result t (f r)
pmap f (ResultPart r p) = ResultPart (f (r mempty) `mappend`) (pmap f p)
pmap f (Choice p1 p2) = Choice (pmap f p1) (pmap f p2)
pmap f (CommitedLeftChoice p1 p2) = CommitedLeftChoice (pmap f p1) (pmap f p2)
pmap f (More g) = More (pmap f . g)
pmap f (LookAhead p c) = LookAhead (pmap f p) (mapThrough c)
   where mapThrough _ Failure = pmap f (c Failure)
         mapThrough c (Result t r) = case c (Result t mempty)
                                     of Failure -> Failure
                                        Result t' r' -> Result t' (r `mappend` f r')
pmap f (LookAheadIgnore p c) = LookAheadIgnore p (pmap f . c)

infixl 3 <<|>
(<<|>) :: Parser s r -> Parser s r -> Parser s r
Failure <<|> p = p
p <<|> Failure = p
p <<|> _ | hasResult p = p
CommitedLeftChoice p1a p1b <<|> p2 = CommitedLeftChoice p1a (p1b <<|> p2)
ResultPart r (CommitedLeftChoice p1a p1b) <<|> p2 = CommitedLeftChoice (resultPart r p1a) (resultPart r p1b <<|> p2)
More f <<|> More g = More (\x-> f x <<|> g x)
p1 <<|> p2 = CommitedLeftChoice p1 p2

infixl 5 ><
(><) :: forall s r. Monoid r => Parser s r -> Parser s r -> Parser s r
Failure >< _ = Failure
Result t r >< p = resultPart (mappend r) (feedList (t []) p)
ResultPart r p1 >< p2 = resultPart r (p1 >< p2)
Choice p1a p1b >< p2 = (p1a >< p2) <|> (p1b >< p2)
More f >< p = More (\x-> f x >< p)
LookAhead p1 c >< p2 = LookAhead p1 ((>< p2) . c)
LookAheadIgnore p1 c >< p2 = LookAheadIgnore p1 ((>< p2) . c)
p1 >< p2 = resolve (>< p2) p1

infixl 5 >><
(>><) :: Monoid r => Parser s r -> Parser s r -> Parser s r
Failure >>< _ = Failure
Result t r >>< p = resultPart (mappend r) (feedList (t []) p)
ResultPart r p1 >>< p2 = resultPart r (p1 >>< p2)
Choice p1a p1b >>< p2 = (p1a >>< p2) <|> (p1b >>< p2)
p1@CommitedLeftChoice{} >>< p2 = 
   CommitedLeftChoice
      (More (\x-> (feed x p1 >>< p2) <<|> (feedEof p1 >>< feed x p2))) 
      (feedEof p1 >>< feedEof p2)
More f >>< p = More (\x-> f x >>< p)
LookAhead p1 c >>< p2 = LookAhead p1 ((>>< p2) . c)
LookAheadIgnore p1 c >>< p2 = LookAheadIgnore p1 ((>>< p2) . c)

longest :: Parser s r -> Parser s r
longest Failure = Failure
longest p@Result{} = p
longest (ResultPart r p) = resultPart r (longest p)
longest (More f) = More (longest . f)
longest (Choice p1 p2@LookAhead{}) = p1 <<|> p2
longest (Choice p1@LookAhead{} p2) = p2 <<|> p1
longest (Choice p1 p2@Result{}) = p1 <<|> p2
longest (Choice p1@Result{} p2) = p2 <<|> p1
longest p = More (\x-> longest $ feed x p) <<|> longest (feedEof p)

duplicate :: Parser s r -> Parser s (Parser s r)
duplicate Failure = Failure
duplicate p@Result{} = Result id p
duplicate p = CommitedLeftChoice (More $ \x-> duplicate (feed x p)) (return p)

-- | A parser that fails on any input.
eof :: Monoid r => Parser s r
eof = lookAheadNotInto (pure mempty) anyToken

-- | A parser that accepts a single input item.
anyToken :: Parser s s
anyToken = More return

-- | A parser that accepts a specific input item.
token :: Eq s => s -> Parser s s
token x = More (\y-> if x == y then return x else Failure)

-- | A parser that accepts an input item only if it satisfies the given predicate.
satisfy :: (s -> Bool) -> Parser s s
satisfy pred = More (\x-> if pred x then return x else Failure)

-- | A parser that accepts a given number of input items.
count :: Int -> Parser s [s]
count n | n > 0 = More (\x-> resultPart (x:) $ count (pred n))
        | otherwise = return []

string :: Eq s => [s] -> Parser s [s]
string whole = stringRest whole
   where stringRest [] = return whole
         stringRest (x : rest) = More (\y-> if x == y then stringRest rest else Failure)

-- | A parser that accepts the longest prefix of input that matches a prefix of the argument list.
prefixOf :: Eq x => [x] -> Parser x [x]
prefixOf list = whilePrefixOf (map (==) list)

-- | A parser that accepts a prefix of input as long as each item satisfies the predicate at the same position in the
-- argument list. The length of the predicate list thus determines the maximum number of acepted values.
whilePrefixOf :: [x -> Bool] -> Parser x [x]
whilePrefixOf (p : rest) = 
   CommitedLeftChoice (More $ \x-> if p x then resultPart (x:) (whilePrefixOf rest) else Failure) (return [])
whilePrefixOf [] = return []

-- | A parser that accepts all input as long as it matches the given predicate.
while :: (x -> Bool) -> Parser x [x]
while p = t
   where t = CommitedLeftChoice (More (\x-> if p x then resultPart (x:) t else Failure)) (return [])

-- | A parser that accepts all input as long as it matches the given predicate, and fails if there isn't any.
while1 :: (x -> Bool) -> Parser x [x]
while1 p = More (\x-> if p x then resultPart (x:) (while p) else Failure)

optional :: Monoid r => Parser s r -> Parser s r
optional p = Choice p (return mempty)

optionMaybe :: Parser s r -> Parser s (Maybe r)
optionMaybe p = fmap Just p <<|> return Nothing

skip :: Monoid r => Parser s r' -> Parser s r
skip p = fmap (const mempty) p

many0 :: Monoid r => Parser s r -> Parser s r
many0 p = many1 p <<|> return mempty

many1 :: Monoid r => Parser s r -> Parser s r
many1 p = More (\x-> feed x p >>< many0 p)

manyTill :: Monoid r => Parser s r -> Parser s r' -> Parser s r
manyTill next end = t
   where t = skip end <<|> (next >>< t)

-- | A parser that accepts all input.
acceptAll :: Parser s [s]
acceptAll = CommitedLeftChoice (More $ \x-> resultPart (x:) acceptAll) (return [])

-- | Parallel parser conjunction: the result of the combinator keeps accepting input as long as both arguments do.
and :: (Monoid r1, Monoid r2) => Parser s r1 -> Parser s r2 -> Parser s (r1, r2)
Failure `and` _ = Failure
_ `and` Failure = Failure
p `and` Result _ r = fmap (\x-> (x, r)) (feedEof p)
Result _ r `and` p = fmap (\x-> (r, x)) (feedEof p)
ResultPart f p1 `and` p2 = fmap (\(r1, r2)-> (f r1, r2)) (p1 `and` p2)
p1 `and` ResultPart f p2 = fmap (\(r1, r2)-> (r1, f r2)) (p1 `and` p2)
Choice p1a p1b `and` p2 = (p1a `and` p2) <|> (p1b `and` p2)
p1 `and` Choice p2a p2b = (p1 `and` p2a) <|> (p1 `and` p2b)
More f `and` p = More (\x-> f x `and` feed x p)
p `and` More f = More (\x-> feed x p `and` f x)
p1 `and` p2 = (feedEof p1 `and` feedEof p2) <|> More (\x-> feed x p1 `and` feed x p2)

andThen :: (Monoid r1, Monoid r2) => Parser s r1 -> Parser s r2 -> Parser s (r1, r2)
Failure `andThen` _ = Failure
Result t r `andThen` p = resultPart (mappend (r, mempty)) (feedList (t []) (fmap ((,) mempty) p))
ResultPart f p1 `andThen` p2 = resultPart (\(r1, r2)-> (f r1, r2)) (p1 `andThen` p2)
Choice p1a p1b `andThen` p2 = (p1a `andThen` p2) <|> (p1b `andThen` p2)
More f `andThen` p = More (\x-> f x `andThen` p)
LookAhead p1 c `andThen` p2 = LookAhead (p1 `andThen` mempty) ((`andThen` p2) . c . fmap fst)
LookAheadIgnore p1 c `andThen` p2 = LookAheadIgnore p1 ((`andThen` p2) . c)
p1 `andThen` p2 = resolve (`andThen` p2) p1
