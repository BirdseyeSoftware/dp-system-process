{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
module Control.Distributed.Process.SystemProcess
       (
       -- * Actor API
         runSystemProcess
       , startSystemProcess
       , sendToProcessStdin
       , terminateProcess

       -- * ProcessSpec constructors
       , shell
       , proc

       -- * ProcessSpec configuration functions
       , castToPid
       , sendToPid
       , sendToChan
       , ignore

       -- * Stream query functions
       , isExitCode
       , isStdOut
       , isStdErr

       , CmdSpec(..)
       , ProcessSpec(..)
       , ProcessStream(..)
       , Transport
       ) where

import Control.Monad (void)
import Control.Monad.Trans (lift, liftIO)

import Data.Binary   (Binary)
import Data.Typeable (Typeable)
import GHC.Generics  (Generic)

import Data.Conduit (awaitForever, ($$))
import Data.Conduit.Binary (sourceHandle)

import Control.Concurrent.Async (async, waitCatch)

import Data.ByteString (hPutStr, ByteString)

import qualified Control.Distributed.Process                         as Process
import qualified Control.Distributed.Process.Platform                as PP
import qualified Control.Distributed.Process.Platform.ManagedProcess as MP
import           Control.Distributed.Process.Platform.Time           (Delay(Infinity))

import           System.Exit (ExitCode(..))
import           System.IO (Handle, hClose)
import qualified System.Process as SProcess

--------------------------------------------------------------------------------
-- Types

data CmdSpec
  = ShellCommand !String
  | RawCommand !FilePath ![String]
  deriving (Show, Generic, Typeable)

instance Binary CmdSpec

--------------------

data ProcessStream
  = StdOut !ByteString
  | StdErr !ByteString
  | ExitCode !Int
  deriving (Show, Generic, Typeable)

instance Binary ProcessStream

isStdErr :: ProcessStream -> Bool
isStdErr (StdErr _) = True
isStdErr _ = False

isStdOut :: ProcessStream -> Bool
isStdOut (StdOut _) = True
isStdOut _ = False

isExitCode :: ProcessStream -> Bool
isExitCode (ExitCode {}) = True
isExitCode _ = False

--------------------

data Transport
  = CastMessage !Process.ProcessId
  | SendMessage !Process.ProcessId
  | SendChan !(Process.SendPort ProcessStream)
  | Ignore
  deriving (Show, Generic, Typeable)

instance Binary Transport

castToPid :: Process.ProcessId -> Transport
castToPid = CastMessage

sendToPid :: Process.ProcessId -> Transport
sendToPid = SendMessage

sendToChan :: Process.SendPort ProcessStream -> Transport
sendToChan = SendChan

ignore :: Transport
ignore = ignore

--------------------

-- data ProcessSpec
--   = ProcessSpec {
--     cmdspec       :: CmdSpec
--   , cwd           :: Maybe FilePath
--   , env           :: Maybe [(String, String)]
--   , std_out       :: Transport
--   , std_err       :: Transport
--   , exit_code     :: Transport
--   , close_fds     :: Bool
--   , create_group  :: Bool
--   , delegate_ctlc :: Bool
--   }
--   deriving (Show, Generic, Typeable)

data ProcessSpec
  = ProcessSpec {
    cmdspec       :: CmdSpec
  , cwd           :: Maybe FilePath
  , env           :: Maybe [(String, String)]
  , std_out       :: Transport
  , std_err       :: Transport
  , exit_code     :: Transport
  , close_fds     :: Bool
  , create_group  :: Bool
  , delegate_ctlc :: Bool
  }
  deriving (Show, Generic, Typeable)

instance Binary ProcessSpec

newtype StdinMessage
  = StdinMessage ByteString
  deriving (Show, Typeable, Binary)

newtype TerminateMessage
  = TerminateMessage ()
  deriving (Show, Typeable, Binary)

type State = (Handle, SProcess.ProcessHandle)

--------------------------------------------------------------------------------
-- [Private] System Process functions

shell :: String -> ProcessSpec
shell cmd = ProcessSpec { cmdspec = ShellCommand cmd
                        , cwd = Nothing
                        , env = Nothing
                        , std_out = ignore
                        , std_err = ignore
                        , exit_code = ignore
                        , close_fds = False
                        , create_group = False
                        , delegate_ctlc = False }

proc :: FilePath -> [String] -> ProcessSpec
proc path args =
  ProcessSpec { cmdspec = RawCommand path args
              , cwd = Nothing
              , env = Nothing
              , std_out = ignore
              , std_err = ignore
              , exit_code = ignore
              , close_fds = False
              , create_group = False
              , delegate_ctlc = False }

shouldSendStream :: Transport -> Bool
shouldSendStream Ignore = False
shouldSendStream _ = True

sendProcessStream :: Transport -> ProcessStream -> Process.Process ()
sendProcessStream (CastMessage pid) = MP.cast pid
sendProcessStream (SendMessage pid) = Process.send pid
sendProcessStream (SendChan chan)   = Process.sendChan chan
sendProcessStream _ = const $ return ()

createHandlerStreamer
  :: Transport
  -> (ByteString -> ProcessStream)
  -> Handle
  -> Process.Process ()
createHandlerStreamer transport streamCtor handle =
    if shouldSendStream transport
      then void $ Process.spawnLocal handleStreamer -- >>= Process.link
      else liftIO $ hClose handle
  where
    handleStreamer =
      sourceHandle handle $$
        awaitForever (lift . sendProcessStream transport . streamCtor)

createExitCodeStreamer
  :: Transport -> SProcess.ProcessHandle -> Process.Process ()
createExitCodeStreamer transport processHandle = do
  exitCodeStreamer <- Process.spawnLocal $ do
    exitCodeAsync <- liftIO . async $ SProcess.waitForProcess processHandle
    exitCode <- liftIO $ waitCatch exitCodeAsync
    case exitCode of
      Right ExitSuccess -> sendProcessStream transport $ ExitCode 0
      Right (ExitFailure n) -> sendProcessStream transport $ ExitCode n
      Left err -> do
        liftIO $ print err
        sendProcessStream transport $ ExitCode 127
  Process.link exitCodeStreamer


--------------------------------------------------------------------------------
-- [Private] Managed Process handlers

handleStdIn :: State
            -> StdinMessage
            -> Process.Process (MP.ProcessAction State)
handleStdIn st@(stdin, _) (StdinMessage bytes) = do
  liftIO $ hPutStr stdin bytes
  MP.continue st

handleTermination :: State
                  -> TerminateMessage
                  -> Process.Process (MP.ProcessReply () State)
handleTermination st@(_, procHandler) _ = do
  liftIO $ SProcess.terminateProcess procHandler
  MP.reply () st

handleShutdown :: State -> PP.ExitReason -> Process.Process ()
handleShutdown (_, procHandler) _ =
  liftIO $ SProcess.terminateProcess procHandler

processDefinition :: MP.ProcessDefinition State
processDefinition =
  MP.defaultProcess  {
    MP.apiHandlers = [
      MP.handleCast handleStdIn
    , MP.handleCall handleTermination
    ]
    , MP.shutdownHandler = handleShutdown
  }

--------------------------------------------------------------------------------
-- Public


runSystemProcess :: ProcessSpec -> Process.Process ()
runSystemProcess procSpec = do
    procAsync <- liftIO . async $ SProcess.createProcess sysProcessSpec
    result <- liftIO $ waitCatch procAsync
    case result of
      Right (Just stdin, Just stdout, Just stderr, procHandler) -> do
        createExitCodeStreamer (exit_code procSpec) procHandler
        createHandlerStreamer  (std_out procSpec) StdOut stdout
        createHandlerStreamer  (std_err procSpec) StdErr stderr
        MP.serve (stdin, procHandler) start processDefinition
      _ ->
        sendProcessStream (exit_code procSpec) (ExitCode 127)
  where
    start = return . flip MP.InitOk Infinity
    sysCmdspec = case cmdspec procSpec of
      RawCommand path args -> SProcess.RawCommand path args
      ShellCommand str -> SProcess.ShellCommand str
    sysProcessSpec = SProcess.CreateProcess {
        SProcess.cmdspec = sysCmdspec
      , SProcess.cwd = cwd procSpec
      , SProcess.env = Nothing
      , SProcess.std_in  = SProcess.CreatePipe
      , SProcess.std_out = SProcess.CreatePipe
      , SProcess.std_err = SProcess.CreatePipe
      , SProcess.close_fds = close_fds procSpec
      , SProcess.create_group = create_group procSpec
      , SProcess.delegate_ctlc = delegate_ctlc procSpec
      }

-- runSystemProcess :: ProcessSpec -> Process.Process ()
-- runSystemProcess processSpec = do
--     procAsync <- liftIO . async $ SProcess.createProcess sysProcessSpec
--     result <- liftIO $ waitCatch procAsync
--     case result of
--       Right (Just stdin, Just stdout, Just stderr, procHandler) -> do
--         createHandlerStreamer  (std_out processSpec) StdOut stdout
--         createHandlerStreamer  (std_err processSpec) StdErr stderr
--         createExitCodeStreamer (exit_code processSpec) procHandler
--         MP.serve (stdin, procHandler) start processDefinition
--       _ -> sendProcessStream (exit_code processSpec) (ExitCode 127)
--   where
--     start = return . flip MP.InitOk Infinity
--     sysCmdSpec =
--       case cmdspec processSpec of
--         ShellCommand txt -> SProcess.ShellCommand txt
--         RawCommand path args -> SProcess.RawCommand path args
--     sysProcessSpec = SProcess.CreateProcess {
--         SProcess.cmdspec = sysCmdSpec
--       , SProcess.cwd = cwd processSpec
--       , SProcess.env = env processSpec
--       , SProcess.std_in  = SProcess.CreatePipe
--       , SProcess.std_out = SProcess.CreatePipe
--       , SProcess.std_err = SProcess.CreatePipe
--       , SProcess.close_fds = close_fds processSpec
--       , SProcess.create_group = create_group processSpec
--       , SProcess.delegate_ctlc = delegate_ctlc processSpec
--       }

startSystemProcess :: ProcessSpec -> Process.Process Process.ProcessId
startSystemProcess = Process.spawnLocal . runSystemProcess

sendToProcessStdin :: Process.ProcessId -> ByteString -> Process.Process ()
sendToProcessStdin pid = MP.cast pid . StdinMessage

terminateProcess :: Process.ProcessId -> Process.Process ()
terminateProcess pid = MP.call pid $ TerminateMessage ()
