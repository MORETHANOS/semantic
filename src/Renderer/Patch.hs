import Data.Functor.Both as Both
import Data.List
patch diff sources = case getLast $ foldMap (Last . Just) string of
  Just c | c /= '\n' -> string ++ "\n\\ No newline at end of file\n"
  _ -> string
  where string = mconcat $ showHunk sources <$> hunks diff sources
hunkLength hunk = mconcat $ (changeLength <$> changes hunk) <> (rowIncrement <$> trailingContext hunk)
changeLength change = mconcat $ (rowIncrement <$> context change) <> (rowIncrement <$> contents change)
-- | The increment the given row implies for line numbering.
rowIncrement :: Row a -> Both (Sum Int)
rowIncrement = fmap lineIncrement
showHunk blobs hunk = header blobs hunk ++
  concat (showChange sources <$> changes hunk) ++
  showLines (snd sources) ' ' (snd <$> trailingContext hunk)
showChange sources change = showLines (snd sources) ' ' (snd <$> context change) ++ deleted ++ inserted
  where (deleted, inserted) = runBoth $ pure showLines <*> sources <*> Both ('-', '+') <*> Both.unzip (contents change)
showLine source line | isEmpty line = Nothing
                     | otherwise = Just . toString . (`slice` source) . unionRanges $ getRange <$> unLine line
hunks _ blobs | Both (True, True) <- null . source <$> blobs = [Hunk { offset = mempty, changes = [], trailingContext = [] }]
hunks diff blobs = hunksInRows (Both (1, 1)) $ fmap (fmap Prelude.fst) <$> splitDiffByLines (source <$> blobs) diff
  Just (change, afterChanges) -> Just (start <> mconcat (rowIncrement <$> skippedContext), change, afterChanges)
rowHasChanges lines = or (lineHasChanges <$> lines)