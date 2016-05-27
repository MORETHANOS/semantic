{-# LANGUAGE RankNTypes #-}
module Alignment
( hasChanges
, numberedRows
, AlignedDiff
, alignDiff
, alignBranch
, applyThese
, modifyJoin
, unionThese
) where

import Control.Arrow ((***))
import Data.Align
import Data.Biapplicative
import Data.Bifunctor.Join
import Data.Function
import Data.Functor.Both as Both
import Data.Functor.Foldable (hylo)
import Data.List (partition)
import Data.Maybe (fromJust)
import qualified Data.OrderedMap as Map
import Data.These
import Diff
import Info
import Patch
import Prologue hiding (fst, snd)
import qualified Prologue
import Range
import Source hiding (break, fromList, uncons, (++))
import SplitDiff
import Syntax
import Term

-- | Assign line numbers to the lines on each side of a list of rows.
numberedRows :: [Join These a] -> [Join These (Int, a)]
numberedRows = countUp (both 1 1)
  where countUp from (row : rows) = fromJust ((,) <$> modifyJoin (uncurry These) from `applyThese` row) : countUp (modifyJoin (fromThese identity identity) (succ <$ row) <*> from) rows
        countUp _ [] = []

-- | Determine whether a line contains any patches.
hasChanges :: SplitDiff leaf Info -> Bool
hasChanges = or . (True <$)

type AlignedDiff leaf = [Join These (SplitDiff leaf Info)]

alignDiff :: Show leaf => Both (Source Char) -> Diff leaf Info -> AlignedDiff leaf
alignDiff sources diff = iter (alignSyntax (runBothWith ((Join .) . These)) (free . Free) getRange sources) (alignPatch sources <$> diff)

alignPatch :: Show leaf => Both (Source Char) -> Patch (Term leaf Info) -> AlignedDiff leaf
alignPatch sources patch = case patch of
  Delete term -> fmap (pure . SplitDelete) <$> hylo (alignSyntax this cofree getRange (Identity (fst sources))) runCofree (Identity <$> term)
  Insert term -> fmap (pure . SplitInsert) <$> hylo (alignSyntax that cofree getRange (Identity (snd sources))) runCofree (Identity <$> term)
  Replace term1 term2 -> fmap (pure . SplitReplace) <$> alignWith (fmap (these identity identity const . runJoin) . Join)
    (hylo (alignSyntax this cofree getRange (Identity (fst sources))) runCofree (Identity <$> term1))
    (hylo (alignSyntax that cofree getRange (Identity (snd sources))) runCofree (Identity <$> term2))
  where getRange = characterRange . extract
        this = Join . This . runIdentity
        that = Join . That . runIdentity

-- | The Applicative instance f is either Identity or Both. Identity is for Terms in Patches, Both is for Diffs in unchanged portions of the diff.
alignSyntax :: (Applicative f, Show term) => (forall a. f a -> Join These a) -> (CofreeF (Syntax leaf) Info term -> term) -> (term -> Range) -> f (Source Char) -> CofreeF (Syntax leaf) (f Info) [Join These term] -> [Join These term]
alignSyntax toJoinThese toNode getRange sources (infos :< syntax) = case syntax of
  Leaf s -> catMaybes $ wrapInBranch (const (Leaf s)) . fmap (flip (,) []) <$> sequenceL lineRanges
  Indexed children -> catMaybes $ wrapInBranch Indexed <$> alignBranch getRange (join children) (modifyJoin (fromThese [] []) lineRanges)
  Fixed children -> catMaybes $ wrapInBranch Fixed <$> alignBranch getRange (join children) (modifyJoin (fromThese [] []) lineRanges)
  Keyed children -> catMaybes $ wrapInBranch (Keyed . Map.fromList) <$> alignBranch (getRange . Prologue.snd) (Map.toList children >>= pairWithKey) (modifyJoin (fromThese [] []) lineRanges)
  where lineRanges = toJoinThese $ actualLineRanges <$> (characterRange <$> infos) <*> sources
        wrapInBranch constructor = applyThese $ toJoinThese ((\ info (range, children) -> toNode (info { characterRange = range } :< constructor children)) <$> infos)
        pairWithKey (key, values) = fmap ((,) key) <$> values

-- | Given a function to get the range, a list of already-aligned children, and the lists of ranges spanned by a branch, return the aligned lines.
alignBranch :: Show term => (term -> Range) -> [Join These term] -> Both [Range] -> [Join These (Range, [term])]
-- There are no more ranges, so we’re done.
alignBranch _ _ (Join ([], [])) = []
-- There are no more children, so we can just zip the remaining ranges together.
alignBranch _ [] ranges = runBothWith (alignWith Join) (fmap (flip (,) []) <$> ranges)
-- There are both children and ranges, so we need to proceed line by line
alignBranch getRange children ranges = case intersectingChildren of
  -- No child intersects the current ranges on either side, so advance.
  [] -> (flip (,) [] <$> headRanges) : alignBranch getRange children (drop 1 <$> ranges)
  -- At least one child intersects on at least one side.
  _ -> case fromThese True True . runJoin . intersects getRange headRanges <$> listToMaybe remainingIntersectingChildren of
    -- At least one child intersects on both sides, so align symmetrically.
    Just (True, True) -> let (line, remaining) = lineAndRemaining intersectingChildren headRanges in
      line : alignBranch getRange (remaining ++ nonIntersectingChildren) (drop 1 <$> ranges)
    -- A symmetrical child intersects on the right, so align asymmetrically on the left.
    Just (False, True) -> let (leftLine, remainingAtLeft) = maybe (id, []) (first (:)) $ lineAndRemaining asymmetricalChildren <$> leftRange in
      leftLine $ alignBranch getRange (remainingAtLeft ++ remainingIntersectingChildren ++ nonIntersectingChildren) (modifyJoin (first (drop 1)) ranges)
    -- A symmetrical child intersects on the left, so align asymmetrically on the right.
    Just (True, False) -> let (rightLine, remainingAtRight) = maybe (id, []) (first (:)) $ lineAndRemaining asymmetricalChildren <$> rightRange in
      rightLine $ alignBranch getRange (remainingAtRight ++ remainingIntersectingChildren ++ nonIntersectingChildren) (modifyJoin (second (drop 1)) ranges)
    -- No symmetrical child intersects, so align asymmetrically, picking the left side first to match the deletion/insertion order convention in diffs.
    _ -> if any (isThis . runJoin) asymmetricalChildren
        then let (leftLine, remainingAtLeft) = maybe (identity, []) (first (:)) $ lineAndRemaining asymmetricalChildren <$> leftRange in
          leftLine $ alignBranch getRange (remainingAtLeft ++ nonIntersectingChildren) (modifyJoin (first (drop 1)) ranges)
        else let (rightLine, remainingAtRight) = maybe (identity, []) (first (:)) $ lineAndRemaining asymmetricalChildren <$> rightRange in
          rightLine $ alignBranch getRange (remainingAtRight ++ nonIntersectingChildren) (modifyJoin (second (drop 1)) ranges)
  where (intersectingChildren, nonIntersectingChildren) = partition (or . intersects getRange headRanges) children
        (remainingIntersectingChildren, asymmetricalChildren) = partition (isThese . runJoin) intersectingChildren
        Just headRanges = sequenceL (listToMaybe <$> Join (runBothWith These ranges))
        (leftRange, rightRange) = splitThese headRanges
        lineAndRemaining children ranges = let (intersections, remaining) = alignChildren getRange children ranges in
          ((,) <$> ranges `applyToBoth` intersections, remaining)

-- | Given a list of aligned children, produce lists of their intersecting first lines, and a list of the remaining lines/nonintersecting first lines.
alignChildren :: (term -> Range) -> [Join These (term)] -> Join These Range -> (Both [term], [Join These term])
alignChildren _ [] _ = (both [] [], [])
alignChildren getRange (first:rest) headRanges
  | ~(l, r) <- splitThese first
  = case fromThese False False . runJoin $ intersects getRange headRanges first of
    -- It intersects on both sides, so we can just take the first line whole.
    (True, True) -> ((++) <$> toTerms first <*> firstRemaining, restRemaining)
    -- It only intersects on the left, so split it up.
    (True, False) -> ((++) <$> toTerms (fromJust l) <*> firstRemaining, maybe identity (:) r restRemaining)
    -- It only intersects on the right, so split it up.
    (False, True) -> ((++) <$> toTerms (fromJust r) <*> firstRemaining, maybe identity (:) l restRemaining)
    -- It doesn’t intersect at all, so skip it and move along.
    (False, False) -> (firstRemaining, first:restRemaining)
  | otherwise = alignChildren getRange rest headRanges
  where (firstRemaining, restRemaining) = alignChildren getRange rest headRanges
        toTerms line = modifyJoin (fromThese [] []) (pure <$> line)

unionThese :: (Alternative f, Foldable f, Monoid (f a)) => f (Join These a) -> Join These (f a)
unionThese as = fromMaybe (Join (These empty empty)) . getUnion . fold $ Union . Just . fmap pure <$> as

-- | Test ranges and terms for intersection on either or both sides.
intersects :: (term -> Range) -> Join These Range -> Join These term -> Join These Bool
intersects getRange ranges line = intersectsRange <$> ranges `applyToBoth` modifyJoin (fromThese (Range (-1) (-1)) (Range (-1) (-1))) (getRange <$> line)

-- | Split a These value up into independent These values representing the left and right sides, if any.
splitThese :: Join These a -> (Maybe (Join These a), Maybe (Join These a))
splitThese these = fromThese Nothing Nothing $ bimap (Just . Join . This) (Just . Join . That) (runJoin these)

infixl 4 `applyThese`

-- | Like `<*>`, but it returns its result in `Maybe` since the result is the intersection of the shapes of the inputs.
applyThese :: Join These (a -> b) -> Join These a -> Maybe (Join These b)
applyThese (Join fg) (Join ab) = fmap Join . uncurry maybeThese $ uncurry (***) (bimap (<*>) (<*>) (unpack fg)) (unpack ab)
  where unpack = fromThese Nothing Nothing . bimap Just Just

infixl 4 `applyToBoth`

-- | Like `<*>`, but it takes a `Both` on the right to ensure that it can always return a value.
applyToBoth :: Join These (a -> b) -> Both a -> Join These b
applyToBoth (Join fg) (Join (a, b)) = Join $ these (This . ($ a)) (That . ($ b)) (\ f g -> These (f a) (g b)) fg

-- Map over the bifunctor inside a Join, producing another Join.
modifyJoin :: (p a a -> q b b) -> Join p a -> Join q b
modifyJoin f = Join . f . runJoin

-- | Given a pair of Maybes, produce a These containing Just their values, or Nothing if they haven’t any.
maybeThese :: Maybe a -> Maybe b -> Maybe (These a b)
maybeThese (Just a) (Just b) = Just (These a b)
maybeThese (Just a) _ = Just (This a)
maybeThese _ (Just b) = Just (That b)
maybeThese _ _ = Nothing

-- | A Monoid wrapping Join These, for which mappend is the smallest shape covering both arguments.
newtype Union a = Union { getUnion :: Maybe (Join These a) }
  deriving (Eq, Functor, Show)


-- | Instances

instance Monoid a => Monoid (Union a) where
  mempty = Union Nothing
  Union (Just a) `mappend` Union (Just b) = Union $ Join <$> uncurry maybeThese (uncurry (***) (bimap mappend mappend (unpack a)) (unpack b))
    where unpack = fromThese Nothing Nothing . runJoin . fmap Just
  Union (Just a) `mappend` _ = Union $ Just a
  Union _ `mappend` Union (Just b) = Union $ Just b
  _ `mappend` _ = Union Nothing

instance Bicrosswalk t => Crosswalk (Join t) where
  crosswalk f = fmap Join . bicrosswalk f f . runJoin
