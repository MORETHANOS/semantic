{-# LANGUAGE RecordWildCards, BangPatterns, DeriveGeneric, RankNTypes #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
module GitmonClient where

import Control.Exception (throw)
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Lazy (toStrict)
import Data.Text (pack, unpack, toLower, isInfixOf)
import qualified Data.Yaml as Y
import GHC.Generics
import Git.Libgit2
import Network.Socket hiding (recv)
import Network.Socket.ByteString (sendAll, recv)
import Prelude
import Prologue hiding (toStrict, error)
import System.Clock
import System.Directory (getCurrentDirectory)
import System.Environment
import System.Timeout

newtype GitmonException = GitmonException String deriving (Show, Typeable)

instance Exception GitmonException


data ProcIO = ProcIO { read_bytes :: Integer
                     , write_bytes :: Integer } deriving (Show, Generic)

instance FromJSON ProcIO


data ProcessData = ProcessUpdateData { gitDir :: String
                                     , program :: String
                                     , realIP :: Maybe String
                                     , repoName :: Maybe String
                                     , via :: String }
                 | ProcessScheduleData
                 | ProcessFinishData { cpu :: Integer
                                     , diskReadBytes :: Integer
                                     , diskWriteBytes :: Integer
                                     , resultCode :: Integer } deriving (Generic, Show)

instance ToJSON ProcessData where
  toJSON = genericToJSON defaultOptions { fieldLabelModifier = camelTo2 '_' }


data GitmonCommand = Update
                   | Finish
                   | Schedule deriving (Generic, Show)

instance ToJSON GitmonCommand where
  toJSON = genericToJSON defaultOptions { constructorTagModifier = unpack . toLower . pack }


data GitmonMsg = GitmonMsg { command :: GitmonCommand
                           , processData :: ProcessData } deriving (Show)

instance ToJSON GitmonMsg where
  toJSON GitmonMsg{..} = object ["command" .= command, "data" .= processData]


type ProcInfo = Either Y.ParseException (Maybe ProcIO)

newtype SocketFactory = SocketFactory { withSocket :: forall a. (Socket -> IO a) -> IO a }

reportGitmon :: String -> ReaderT LgRepo IO a -> ReaderT LgRepo IO a
reportGitmon = reportGitmon' SocketFactory { withSocket = withGitmonSocket }

reportGitmon' :: SocketFactory -> String -> ReaderT LgRepo IO a -> ReaderT LgRepo IO a
reportGitmon' SocketFactory{..} program gitCommand = do
  (gitDir, realIP, repoName) <- liftIO loadEnvVars
  (startTime, beforeProcIOContents) <- liftIO collectStats

  gitmonStatus <- safeIO . timeout gitmonTimeout . withSocket $ \s -> do
    sendAll s $ processJSON Update (ProcessUpdateData gitDir program realIP repoName "semantic-diff")
    sendAll s $ processJSON Schedule ProcessScheduleData
    recv s 1024

  !result <- withGitmonStatus (join gitmonStatus) gitCommand

  (afterTime, afterProcIOContents) <- liftIO collectStats
  let (cpuTime, diskReadBytes, diskWriteBytes, resultCode) = procStats startTime afterTime beforeProcIOContents afterProcIOContents
  safeIO . withSocket . flip sendAll $ processJSON Finish (ProcessFinishData cpuTime diskReadBytes diskWriteBytes resultCode)

  pure result

  where
    withGitmonStatus :: Maybe ByteString -> ReaderT LgRepo IO a -> ReaderT LgRepo IO a
    withGitmonStatus maybeGitmonStatus gitCommand = case maybeGitmonStatus of
      Just gitmonStatus | "fail" `isInfixOf` decodeUtf8 gitmonStatus -> throwGitmonException gitmonStatus
      _ -> gitCommand

    throwGitmonException :: ByteString -> e
    throwGitmonException command = throw . GitmonException . unpack $ "Received: '" <> decodeUtf8 command <> "' from Gitmon"

    collectStats :: IO (TimeSpec, ProcInfo)
    collectStats = do
      time <- getTime clock
      procIOContents <- Y.decodeFileEither procFileAddr :: IO ProcInfo
      pure (time, procIOContents)

    procStats :: TimeSpec -> TimeSpec -> ProcInfo -> ProcInfo -> ( Integer, Integer, Integer, Integer )
    procStats beforeTime afterTime beforeProcIOContents afterProcIOContents = ( cpuTime, diskReadBytes, diskWriteBytes, resultCode )
      where
        cpuTime = toNanoSecs afterTime - toNanoSecs beforeTime
        beforeDiskReadBytes = either (const 0) (maybe 0 read_bytes) beforeProcIOContents
        afterDiskReadBytes = either (const 0) (maybe 0 read_bytes) afterProcIOContents
        beforeDiskWriteBytes = either (const 0) (maybe 0 write_bytes) beforeProcIOContents
        afterDiskWriteBytes = either (const 0) (maybe 0 write_bytes) afterProcIOContents
        diskReadBytes = afterDiskReadBytes - beforeDiskReadBytes
        diskWriteBytes = afterDiskWriteBytes - beforeDiskWriteBytes
        resultCode = 0

    loadEnvVars :: IO (String, Maybe String, Maybe String)
    loadEnvVars = do
      pwd <- safeGetCurrentDirectory
      gitDir <- fromMaybe pwd <$> lookupEnv "GIT_DIR"
      realIP <- lookupEnv "GIT_SOCKSTAT_VAR_real_ip"
      repoName <- lookupEnv "GIT_SOCKSTAT_VAR_repo_name"
      pure (gitDir, realIP, repoName)
      where
        safeGetCurrentDirectory :: IO String
        safeGetCurrentDirectory = getCurrentDirectory `catch` handleIOException

        handleIOException :: IOException -> IO String
        handleIOException _ = pure ""

withGitmonSocket :: (Socket -> IO c) -> IO c
withGitmonSocket = bracket connectSocket close
  where
    connectSocket = do
      s <- socket AF_UNIX Stream defaultProtocol
      connect s (SockAddrUnix gitmonSocketAddr)
      pure s

-- Timeout in nanoseconds to wait before giving up on Gitmon response to schedule.
gitmonTimeout :: Int
gitmonTimeout = 1 * 1000 * 1000

gitmonSocketAddr :: String
gitmonSocketAddr = "/tmp/gitstats.sock"

procFileAddr :: String
procFileAddr = "/proc/self/io"

clock :: Clock
clock = Realtime

processJSON :: GitmonCommand -> ProcessData -> ByteString
processJSON command processData = (toStrict . encode $ GitmonMsg command processData) <> "\n"

safeIO :: MonadIO m => IO a -> m (Maybe a)
safeIO command = liftIO $ (Just <$> command) `catch` noop

noop :: IOException -> IO (Maybe a)
noop _ = pure Nothing
