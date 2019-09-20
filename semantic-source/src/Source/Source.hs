{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving #-}
{-|
'Source' models source code, represented as a thin wrapper around a 'B.ByteString' with conveniences for splitting by line, slicing, etc.

This module is intended to be imported qualified to avoid name clashes with 'Prelude':

> import qualified Source.Source as Source
-}
module Source.Source
( Source
, sourceBytes
, fromUTF8
-- * Measurement
, Source.Source.length
, Source.Source.null
, totalRange
, totalSpan
-- * En/decoding
, fromText
, toText
-- * Slicing
, slice
, dropSource
, takeSource
-- * Splitting
, Source.Source.lines
, lineRanges
, lineRangesWithin
, newlineIndices
) where

import           Control.Arrow ((&&&))
import           Data.Aeson (FromJSON (..), withText)
import qualified Data.ByteString as B
import           Data.Char (ord)
import           Data.Maybe (fromMaybe)
import           Data.Monoid (Last(..))
import           Data.Semilattice.Lower
import           Data.String (IsString (..))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           GHC.Generics (Generic)
import           Source.Range
import           Source.Span hiding (HasSpan (..))


-- | The contents of a source file. This is represented as a UTF-8
-- 'ByteString' under the hood. Construct these with 'fromUTF8'; obviously,
-- passing 'fromUTF8' non-UTF8 bytes will cause crashes.
newtype Source = Source { sourceBytes :: B.ByteString }
  deriving (Eq, Semigroup, Monoid, IsString, Show, Generic)

fromUTF8 :: B.ByteString -> Source
fromUTF8 = Source

instance FromJSON Source where
  parseJSON = withText "Source" (pure . fromText)


-- Measurement

length :: Source -> Int
length = B.length . sourceBytes

null :: Source -> Bool
null = B.null . sourceBytes

-- | Return a 'Range' that covers the entire text.
totalRange :: Source -> Range
totalRange = Range 0 . B.length . sourceBytes

-- | Return a 'Span' that covers the entire text.
totalSpan :: Source -> Span
totalSpan source = Span lowerBound (Pos (Prelude.length ranges) (succ (end lastRange - start lastRange))) where
  ranges = lineRanges source
  lastRange = fromMaybe lowerBound (getLast (foldMap (Last . Just) ranges))


-- En/decoding

-- | Return a 'Source' from a 'Text'.
fromText :: T.Text -> Source
fromText = Source . T.encodeUtf8

-- | Return the Text contained in the 'Source'.
toText :: Source -> T.Text
toText = T.decodeUtf8 . sourceBytes


-- Slicing

-- | Return a 'Source' that contains a slice of the given 'Source'.
slice :: Source -> Range -> Source
slice source range = take $ drop source where
  drop = dropSource (start range)
  take = takeSource (rangeLength range)

dropSource :: Int -> Source -> Source
dropSource i = Source . B.drop i . sourceBytes

takeSource :: Int -> Source -> Source
takeSource i = Source . B.take i . sourceBytes


-- Splitting

-- | Split the contents of the source after newlines.
lines :: Source -> [Source]
lines source = slice source <$> lineRanges source

-- | Compute the 'Range's of each line in a 'Source'.
lineRanges :: Source -> [Range]
lineRanges source = lineRangesWithin (totalRange source) source

-- | Compute the 'Range's of each line in a 'Range' of a 'Source'.
lineRangesWithin :: Range -> Source -> [Range]
lineRangesWithin range
  = uncurry (zipWith Range)
  . ((start range:) &&& (<> [ end range ]))
  . fmap (+ succ (start range))
  . newlineIndices
  . sourceBytes
  . flip slice range

-- | Return all indices of newlines ('\n', '\r', and '\r\n') in the 'ByteString'.
newlineIndices :: B.ByteString -> [Int]
newlineIndices = go 0 where
  go n bs
    | B.null bs = []
    | otherwise = case (searchCR bs, searchLF bs) of
      (Nothing, Nothing)  -> []
      (Just i, Nothing)   -> recur n i bs
      (Nothing, Just i)   -> recur n i bs
      (Just crI, Just lfI)
        | succ crI == lfI -> recur n lfI bs
        | otherwise       -> recur n (min crI lfI) bs
  recur n i bs = let j = n + i in j : go (succ j) (B.drop (succ i) bs)
  searchLF = B.elemIndex (toEnum (ord '\n'))
  searchCR = B.elemIndex (toEnum (ord '\r'))
{-# INLINE newlineIndices #-}
