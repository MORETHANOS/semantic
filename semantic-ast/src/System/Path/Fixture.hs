{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ImplicitParams #-}

module System.Path.Fixture
  ( absRelFile,
    HasFixture,
    absRelDir,
    delay,
    create,
  )
where

import Control.Concurrent
import GHC.Stack
import System.FilePath
import System.IO

#if BAZEL_BUILD
import qualified Bazel.Runfiles as Bazel

type HasFixture =
  ( ?runfiles :: Bazel.Runfiles,
    ?project :: Path.RelDir,
    HasCallStack
  )

create :: IO Bazel.Runfiles
create = Bazel.create

root :: HasFixture => FilePath
root = Path.absRel (Bazel.rlocation ?runfiles ".")

absRelFile :: (HasFixture) => String -> FilePath
absRelFile x = Path.toAbsRel (root </> Path.relDir "semantic" </> ?project </> Path.relFile x)

absRelDir :: HasFixture => String -> FilePath
absRelDir x = Path.toAbsRel (root </> Path.relDir "semantic" </> ?project </> Path.relDir x)

#else

-- building under Cabal
type HasFixture = HasCallStack

create :: IO ()
create = pure ()

absRelFile :: String -> FilePath
absRelFile x = "semantic" </> x

absRelDir :: String -> FilePath
absRelDir x = "semantic" </> x

#endif

delay :: String -> IO ()
delay s = do
  putStrLn s
  hFlush stdout
  threadDelay 100000000
