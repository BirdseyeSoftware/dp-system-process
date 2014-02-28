WARNING! This is a work in progress, and it is still experimental, use it at your own risk

# dp-system-process

This library allows the creation of system processes using the distributed-process
Actor's library.

# Installation and usage

This library requires using cabal sandbox with the following sub-projects (mind the 'development' branch part):

* [distributed-process](https://github.com/haskell-distributed/distributed-process/tree/development)
* [distributed-process-platform](https://github.com/haskell-distributed/distributed-process-platform/tree/development)
* [network-transport](https://github.com/haskell-distributed/network-transport/tree/development)

In order to run tests, you'll also need
[network-transport-inmemory](https://github.com/haskell-distributed/network-transport-inmemory/tree/development)

There is a `Makefile` in that would facilitate running the test suite, just do `make test`.

# Documentation

Currently you can read the documentation by doing `cabal haddock` and accessing it through dist/doc folder

# Example

The API tries to replicate as much as it can from `System.Process`, there are bits that change
specifically on the std_out, std_err, std_in, there is also a new filed called exit_code.

You may send `ByteString`s to the process std_in by using the `sendToProcessStdIn` function.

An example to better explain how it works:

```haskell
import Control.Monad (forever)
import Control.Monad.Trans (liftIO)

import Control.Concurrent (threadDelay)

import Network.Transport.Chan (createTransport)
import Control.Distributed.Process.Node (runProcess, newLocalNode, initRemoteTable)
import qualified Control.Distributed.Process as Process

import Control.Distributed.Process.SystemProcess as Proc

main :: IO ()
main = do
  -- Cloud Haskell boilerplate
  transport <- createTransport
  node <- newLocalNode transport initRemoteTable
  runProcess node $ do

    -- Actual example

    -- Listener is going to receive stdout and exit code from the system process actor
    listenerPid <- Process.spawnLocal $ do
      forever $
        Process.receiveWait [ Process.matchIf Proc.isExitCode (liftIO . print)
                            , Process.matchIf Proc.isStdOut (liftIO . print) ]

    -- current actor is going to become the process actor
    Proc.runSystemProcess
      -- Process.send std_out and exit_code to listenerPid
      -- There are different transports, check the haddock documentation
      (Proc.proc "ls" ["-l", "-a"]) { Proc.std_out = Proc.sendToPid listenerPid
                                    , Proc.exit_code = Proc.sendToPid listenerPid }

    liftIO $ threadDelay 10000
    Process.kill listenerPid "time to die..."
```