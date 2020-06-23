{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}

-- just to use 'debugTracer'
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
-- `ShowProxy (ReqResp req resp)` is an orphaned instance
{-# OPTIONS_GHC -Wno-orphans               #-}

module Test.Ouroboros.Network.ConnectionManager.Server
  ( tests
  ) where

import           Control.Monad (replicateM)
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadThrow
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadST    (MonadST)
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadSay
import           Control.Monad.Class.MonadTime  (MonadTime)
import           Control.Monad.Class.MonadTimer
import           Control.Tracer (Tracer (..), contramap, nullTracer, traceWith)

import           Codec.Serialise.Class (Serialise)
import           Data.ByteString.Lazy (ByteString)
import           Data.Either (partitionEithers)
import           Data.Foldable (fold)
import           Data.Functor (($>))
import           Data.List (mapAccumL)
import           Data.List.NonEmpty (NonEmpty (..))
import           Data.Typeable (Typeable)
import           Data.Void (Void)

import           Test.QuickCheck
import           Test.Tasty (TestTree, testGroup)
import           Test.Tasty.QuickCheck (testProperty)

import qualified Network.Mux as Mux
import qualified Network.Socket as Socket
import           Network.TypedProtocol.Core

import           Network.TypedProtocol.ReqResp.Type (ReqResp)
import           Network.TypedProtocol.ReqResp.Codec.CBOR
import           Network.TypedProtocol.ReqResp.Client
import           Network.TypedProtocol.ReqResp.Server
import           Network.TypedProtocol.ReqResp.Examples

import           Ouroboros.Network.Channel (fromChannel)
import           Ouroboros.Network.ConnectionId
import           Ouroboros.Network.ConnectionHandler
import           Ouroboros.Network.ConnectionManager.Server (ServerArguments (..))
import qualified Ouroboros.Network.ConnectionManager.Server as Server
import qualified Ouroboros.Network.ConnectionManager.Server.ControlChannel as Server
import           Ouroboros.Network.ConnectionManager.Core
import           Ouroboros.Network.HasIPAddress
import           Ouroboros.Network.RethrowPolicy
import           Ouroboros.Network.ConnectionManager.Types
import           Ouroboros.Network.IOManager
import           Ouroboros.Network.Mux
import           Ouroboros.Network.Protocol.Handshake
import           Ouroboros.Network.Protocol.Handshake.Codec (cborTermVersionDataCodec)
import           Ouroboros.Network.Protocol.Handshake.Unversioned
import           Ouroboros.Network.Protocol.Handshake.Version (Acceptable (..))
import           Ouroboros.Network.Server.RateLimiting (AcceptedConnectionsLimit (..))
import           Ouroboros.Network.Snocket (Snocket, socketSnocket)
import qualified Ouroboros.Network.Snocket as Snocket
import           Ouroboros.Network.Util.ShowProxy


tests :: TestTree
tests =
  testGroup "Ouroboros.Network.ConnectionManager.Server"
  [ testProperty "unidirectional_IO" prop_unidirectional_IO
  , testProperty "bidirectional_IO"  prop_bidirectional_IO
  ]

instance ShowProxy (ReqResp req resp) where
    showProxy _ = "ReqResp"

--
-- Server tests (IO only)
--

-- | The protocol will run three instances of  `ReqResp` protocol; one for each
-- state: warm, hot and established.
--
data ClientAndServerData req resp acc = ClientAndServerData {
    responderAccumulatorFn          :: Fun (acc, req) (acc, resp),
    -- ^ folding function as required by `mapAccumL`, `acc -> req -> (acc, res)`
    -- written using QuickCheck's 'Fun' type; all three responders (hot \/ warm
    -- and established) are using the same
    -- accumulation function, but different initial values.
    hotResponderAccumulator         :: acc,
    -- ^ initial accumulator value for hot responder
    warmResponderAccumulator        :: acc,
    -- ^ initial accumulator value for worm responder
    establishedResponderAccumulator :: acc,
    -- ^ initial accumulator value for established responder
    hotInitiatorRequests            :: [[req]],
    -- ^ list of requests run by the hot intiator in each round; Running
    -- multiple rounds allows us to test restarting of responders.
    warmInitiatorRequests           :: [[req]],
    -- ^ list of requests run by the warm intiator in each round
    establishedInitiatorRequests    :: [[req]]
    -- ^ lsit of requests run by the established intiator in each round
  }
  deriving Show


-- Number of rounds to exhoust all the requests.
--
numberOfRounds :: ClientAndServerData req resp acc ->  Int
numberOfRounds ClientAndServerData {
                  hotInitiatorRequests,
                  warmInitiatorRequests,
                  establishedInitiatorRequests
                } =
    length hotInitiatorRequests
    `max`
    length warmInitiatorRequests
    `max`
    length establishedInitiatorRequests


arbitraryList :: Arbitrary a =>  Gen [[a]]
arbitraryList =
    resize 5 (listOf (resize 10 (listOf (resize 100 arbitrary))))

instance ( Arbitrary req
         , Arbitrary resp
         , Arbitrary acc
         , Function acc
         , CoArbitrary acc
         , Function req
         , CoArbitrary req
         ) => Arbitrary (ClientAndServerData req resp acc) where
    arbitrary =
      ClientAndServerData <$> arbitrary
                          <*> arbitrary
                          <*> arbitrary
                          <*> arbitrary
                          <*> arbitraryList
                          <*> arbitraryList
                          <*> arbitraryList


expectedResult :: ClientAndServerData req resp acc
               -> ClientAndServerData req resp acc
               -> Bundle [resp]
expectedResult ClientAndServerData { hotInitiatorRequests
                                   , warmInitiatorRequests
                                   , establishedInitiatorRequests
                                   }
               ClientAndServerData { responderAccumulatorFn
                                   , hotResponderAccumulator
                                   , warmResponderAccumulator
                                   , establishedResponderAccumulator
                                   } =
  Bundle
    (WithHot
      (snd $ mapAccumL
        (applyFun2 responderAccumulatorFn)
        hotResponderAccumulator
        (concat hotInitiatorRequests)))
    (WithWarm
      (snd $ mapAccumL
        (applyFun2 responderAccumulatorFn)
        warmResponderAccumulator
        (concat warmInitiatorRequests)))
    (WithEstablished
      (snd $ mapAccumL
        (applyFun2 responderAccumulatorFn)
        establishedResponderAccumulator
        (concat establishedInitiatorRequests)))


--
-- Various ConnectionManagers
--

type ConnectionManagerMonad m =
       ( MonadAsync m, MonadCatch m, MonadEvaluate m, MonadFork m, MonadMask  m
       , MonadST m, MonadTime m, MonadTimer m, MonadThrow m, MonadThrow (STM m)
       )

-- | Initiator only connection manager.
--
withInitiatorOnlyConnectionManager
    :: forall peerAddr socket acc req resp m a.
       ( ConnectionManagerMonad m

       , Ord peerAddr, Show peerAddr, Typeable peerAddr
       , Serialise req, Serialise resp
       , Typeable req, Typeable resp

       -- debugging
       , MonadSay m, Show req, Show resp
       )
    => String
    -- ^ identifier (for logging)
    -> Snocket m socket peerAddr
    -> ClientAndServerData req resp acc
    -- ^ series of request possible to do with the bidirectional connection
    -- manager towards some peer.
    -> (MuxConnectionManager
          InitiatorMode socket peerAddr
          UnversionedProtocol ByteString m [resp] Void
       -> m a)
    -> m a
withInitiatorOnlyConnectionManager
    name snocket
    ClientAndServerData {
        hotInitiatorRequests,
        warmInitiatorRequests,
        establishedInitiatorRequests
      }
    k = do
    mainThreadId <- myThreadId
    -- we pass a `StricTVar` with all the reuqests to each initiator.  This way
    -- the each round (which runs a single instance of `ReqResp` protocol) will
    -- use its own request list.
    hotRequestsVar         <- newTVarIO hotInitiatorRequests
    warmRequestsVar        <- newTVarIO warmInitiatorRequests
    establishedRequestsVar <- newTVarIO establishedInitiatorRequests
    withConnectionManager
      ConnectionManagerArguments {
          -- ConnectionManagerTrace
          cmTracer    = (name,) `contramap` connectionManagerTracer,
         -- MuxTracer
          cmMuxTracer = (name,) `contramap` nullTracer,
          cmIPv4Address = Nothing,
          cmIPv6Address = Nothing,
          cmSnocket = snocket,
          cmHasIPAddress = WithInitiatorMode idHasIPv4Address,
          connectionHandler =
            makeConnectionHandler
              ((name,) `contramap` nullTracer) -- mux tracer
              SInitiatorMode
              clientMiniProtocolBundle
              HandshakeArguments {
                  -- TraceSendRecv
                  haHandshakeTracer = (name,) `contramap` nullTracer,
                  haHandshakeCodec = unversionedHandshakeCodec,
                  haVersionDataCodec = cborTermVersionDataCodec unversionedProtocolDataCodec,
                  haVersions = unversionedProtocol
                    (clientApplication
                      hotRequestsVar
                      warmRequestsVar
                      establishedRequestsVar),
                  haAcceptVersion = acceptableVersion
                }
              (\_ _ -> Duplex)
              (\_ _ -> pure ())
              (mainThreadId, RethrowPolicy (\_ _ -> ShutdownNode)),
          connectionDataFlow = const Duplex,
          cmPrunePolicy = simplePrunePolicy,
          cmConnectionsLimits = AcceptedConnectionsLimit {
              acceptedConnectionsHardLimit = maxBound,
              acceptedConnectionsSoftLimit = maxBound,
              acceptedConnectionsDelay     = 0
            },
          cmClassifyHandleError = \_ -> HandshakeFailure,
          cmLocalIPs = return mempty
        }
      k
  where
    clientMiniProtocolBundle :: Mux.MiniProtocolBundle InitiatorMode
    clientMiniProtocolBundle = Mux.MiniProtocolBundle
        [ Mux.MiniProtocolInfo {
            Mux.miniProtocolNum = Mux.MiniProtocolNum 1,
            Mux.miniProtocolDir = Mux.InitiatorDirectionOnly,
            Mux.miniProtocolLimits = Mux.MiniProtocolLimits maxBound
          }
        , Mux.MiniProtocolInfo {
            Mux.miniProtocolNum = Mux.MiniProtocolNum 2,
            Mux.miniProtocolDir = Mux.InitiatorDirectionOnly,
            Mux.miniProtocolLimits = Mux.MiniProtocolLimits maxBound
          }
        , Mux.MiniProtocolInfo {
            Mux.miniProtocolNum = Mux.MiniProtocolNum 3,
            Mux.miniProtocolDir = Mux.InitiatorDirectionOnly,
            Mux.miniProtocolLimits = Mux.MiniProtocolLimits maxBound
          }
        ]

    clientApplication :: StrictTVar m [[req]]
                      -> StrictTVar m [[req]]
                      -> StrictTVar m [[req]]
                      -> Bundle
                          (ConnectionId peerAddr
                      -> ControlMessageSTM m
                      -> [MiniProtocol InitiatorMode ByteString m [resp] Void])
    clientApplication hotRequestsVar
                      warmRequestsVar
                      establishedRequestsVar = Bundle {
        withHot = WithHot $ \_ _ ->
          [ let miniProtocolNum = Mux.MiniProtocolNum 1
            in MiniProtocol {
                miniProtocolNum,
                miniProtocolLimits = Mux.MiniProtocolLimits maxBound,
                miniProtocolRun =
                  reqRespInitiator
                    miniProtocolNum
                    hotRequestsVar
               }
          ],
        withWarm = WithWarm $ \_ _ ->
          [ let miniProtocolNum = Mux.MiniProtocolNum 2
            in MiniProtocol {
                miniProtocolNum,
                miniProtocolLimits = Mux.MiniProtocolLimits maxBound,
                miniProtocolRun =
                  reqRespInitiator
                    miniProtocolNum
                    warmRequestsVar
              }
          ],
        withEstablished = WithEstablished $ \_ _ ->
          [ let miniProtocolNum = Mux.MiniProtocolNum 3
            in MiniProtocol {
                miniProtocolNum,
                miniProtocolLimits = Mux.MiniProtocolLimits maxBound,
                miniProtocolRun =
                  reqRespInitiator
                    (Mux.MiniProtocolNum 3)
                    establishedRequestsVar
              }
          ]
      }

    reqRespInitiator :: Mux.MiniProtocolNum
                     -> StrictTVar m [[req]]
                     -> RunMiniProtocol InitiatorMode ByteString m [resp] Void
    reqRespInitiator protocolNum requestsVar =
      InitiatorProtocolOnly
        (MuxPeer
          ((localAddress,"Initiator",protocolNum,) `contramap` nullTracer) -- TraceSendRecv
          codecReqResp
          (Effect $ do
            reqs <-
              atomically $ do
                requests <- readTVar requestsVar
                case requests of
                  (reqs : rest) -> do
                    writeTVar requestsVar rest $> reqs
                  [] -> pure []
            pure $ 
              reqRespClientPeer
              (reqRespClientMap reqs)))


-- | Runs an example server which runs a single 'ReqResp' protocol for any hot
-- \/ warm \/ established peers and also gives access to bidirectional
-- 'ConnectionManager'.  This gives a way to connect to other peers.
-- Slightly unfortunate design decision does not give us a way to create
-- a client per connection.  This means that this connection manager takes list
-- of 'req' type which it will make to the other side (they will be multiplexed
-- across warm \/ how \/ established) protocols.
--
withBidirectionalConnectionManager
    :: forall peerAddr socket acc req resp m a.
       ( ConnectionManagerMonad m

       , Ord peerAddr, Show peerAddr, Typeable peerAddr
       , Serialise req, Serialise resp
       , Typeable req, Typeable resp

       -- debugging
       , MonadSay m, Show req, Show resp
       )
    => String
    -- ^ identifier (for logging)
    -> Snocket m socket peerAddr
    -> socket
    -- ^ listening socket
    -> Maybe peerAddr
    -> ClientAndServerData req resp acc
    -- ^ series of request possible to do with the bidirectional connection
    -- manager towards some peer.
    -> (MuxConnectionManager
          InitiatorResponderMode socket peerAddr
          UnversionedProtocol ByteString m [resp] acc
       -> peerAddr
       -> m a)
    -> m a
withBidirectionalConnectionManager name snocket socket localAddress
                                   ClientAndServerData {
                                       responderAccumulatorFn,
                                       hotResponderAccumulator,
                                       warmResponderAccumulator,
                                       establishedResponderAccumulator,
                                       hotInitiatorRequests,
                                       warmInitiatorRequests,
                                       establishedInitiatorRequests
                                     }
                                   k = do
    mainThreadId <- myThreadId
    serverControlChannel      <- Server.newControlChannel
    -- as in the 'withInitiatorOnlyConnectionManager' we use a `StrictTVar` to
    -- pass list of requests, but since we are also interested in the results we
    -- need to have multable cells to pass the accumulators around.
    hotRequestsVar            <- newTVarIO hotInitiatorRequests
    warmRequestsVar           <- newTVarIO warmInitiatorRequests
    establishedRequestsVar    <- newTVarIO establishedInitiatorRequests
    hotAccumulatorVar         <- newTVarIO hotResponderAccumulator
    warmAccumulatorVar        <- newTVarIO warmResponderAccumulator
    establishedAccumulatorVar <- newTVarIO establishedResponderAccumulator
    -- we are not using the randomness
    serverStateVar            <- Server.newStateVarFromSeed 0

    withConnectionManager
      ConnectionManagerArguments {
          -- ConnectionManagerTrace
          cmTracer       = (name,) `contramap` connectionManagerTracer,
          -- MuxTracer
          cmMuxTracer    = (name,) `contramap` nullTracer,
          cmIPv4Address  = localAddress,
          cmIPv6Address  = Nothing,
          cmSnocket      = snocket,
          cmHasIPAddress = WithInitiatorResponderMode idHasIPv4Address (),
          connectionHandler =
            makeConnectionHandler
              -- mux tracer
              ((name,) `contramap` nullTracer)
              SInitiatorResponderMode
              serverMiniProtocolBundle
              HandshakeArguments {
                  -- TraceSendRecv
                  haHandshakeTracer = (name,) `contramap` nullTracer,
                  haHandshakeCodec = unversionedHandshakeCodec,
                  haVersionDataCodec = cborTermVersionDataCodec unversionedProtocolDataCodec,
                  haVersions = unversionedProtocol
                                (serverApplication 
                                  hotRequestsVar
                                  warmRequestsVar
                                  establishedRequestsVar
                                  hotAccumulatorVar
                                  warmAccumulatorVar
                                  establishedAccumulatorVar),
                  haAcceptVersion = acceptableVersion
                }
              (\_ _ -> Duplex)
              (Server.newOutboundConnection serverControlChannel)
              (mainThreadId, RethrowPolicy (\_ _ -> ShutdownNode)),
          connectionDataFlow = const Duplex,
          cmPrunePolicy = simplePrunePolicy,
          cmConnectionsLimits = AcceptedConnectionsLimit {
              acceptedConnectionsHardLimit = maxBound,
              acceptedConnectionsSoftLimit = maxBound,
              acceptedConnectionsDelay     = 0
            },
          cmClassifyHandleError = \_ -> HandshakeFailure,
          cmLocalIPs = return mempty
        }
      $ \connectionManager -> do
            serverAddr <- Snocket.getLocalAddr snocket socket
            withAsync
              (Server.run
                ServerArguments {
                    serverSockets = socket :| [],
                    serverSnocket = snocket,
                    serverTracer = (name,) `contramap` nullTracer, -- ServerTrace
                    serverConnectionLimits = AcceptedConnectionsLimit maxBound maxBound 0,
                    serverConnectionManager = connectionManager,
                    serverControlChannel,
                    serverStateVar
                  }
              )
              (\_ -> k connectionManager serverAddr)
  where
    -- for a bidirectional mux we need to define 'Mu.xMiniProtocolInfo' for each
    -- protocol for each direction.
    serverMiniProtocolBundle :: Mux.MiniProtocolBundle InitiatorResponderMode
    serverMiniProtocolBundle = Mux.MiniProtocolBundle
        [ Mux.MiniProtocolInfo {
            Mux.miniProtocolNum = Mux.MiniProtocolNum 1,
            Mux.miniProtocolDir = Mux.ResponderDirection,
            Mux.miniProtocolLimits = Mux.MiniProtocolLimits maxBound
          }
        , Mux.MiniProtocolInfo {
            Mux.miniProtocolNum = Mux.MiniProtocolNum 1,
            Mux.miniProtocolDir = Mux.InitiatorDirection,
            Mux.miniProtocolLimits = Mux.MiniProtocolLimits maxBound
          }
        , Mux.MiniProtocolInfo {
            Mux.miniProtocolNum = Mux.MiniProtocolNum 2,
            Mux.miniProtocolDir = Mux.ResponderDirection,
            Mux.miniProtocolLimits = Mux.MiniProtocolLimits maxBound
          }
        , Mux.MiniProtocolInfo {
            Mux.miniProtocolNum = Mux.MiniProtocolNum 2,
            Mux.miniProtocolDir = Mux.InitiatorDirection,
            Mux.miniProtocolLimits = Mux.MiniProtocolLimits maxBound
          }
        , Mux.MiniProtocolInfo {
            Mux.miniProtocolNum = Mux.MiniProtocolNum 3,
            Mux.miniProtocolDir = Mux.ResponderDirection,
            Mux.miniProtocolLimits = Mux.MiniProtocolLimits maxBound
          }
        , Mux.MiniProtocolInfo {
            Mux.miniProtocolNum = Mux.MiniProtocolNum 3,
            Mux.miniProtocolDir = Mux.InitiatorDirection,
            Mux.miniProtocolLimits = Mux.MiniProtocolLimits maxBound
          }
        ]

    serverApplication :: StrictTVar m [[req]]
                      -> StrictTVar m [[req]]
                      -> StrictTVar m [[req]]
                      -> StrictTVar m acc
                      -> StrictTVar m acc
                      -> StrictTVar m acc
                      -> Bundle
                          (ConnectionId peerAddr
                      -> ControlMessageSTM m
                      -> [MiniProtocol InitiatorResponderMode ByteString m [resp] acc])
    serverApplication hotRequestsVar
                      warmRequestsVar
                      establishedRequestsVar
                      hotAccumulatorVar
                      warmAccumulatorVar
                      establishedAccumulatorVar
                      = Bundle {
        withHot = WithHot $ \_ _ ->
          [ let miniProtocolNum = Mux.MiniProtocolNum 1
            in MiniProtocol {
                miniProtocolNum,
                miniProtocolLimits = Mux.MiniProtocolLimits maxBound,
                miniProtocolRun =
                  reqRespInitiatorAndResponder
                    miniProtocolNum
                    responderAccumulatorFn
                    hotAccumulatorVar
                    hotRequestsVar
               }
          ],
        withWarm = WithWarm $ \_ _ ->
          [ let miniProtocolNum = Mux.MiniProtocolNum 2
            in MiniProtocol {
                miniProtocolNum,
                miniProtocolLimits = Mux.MiniProtocolLimits maxBound,
                miniProtocolRun =
                  reqRespInitiatorAndResponder
                    miniProtocolNum
                    responderAccumulatorFn
                    warmAccumulatorVar
                    warmRequestsVar
              }
          ],
        withEstablished = WithEstablished $ \_ _ ->
          [ let miniProtocolNum = Mux.MiniProtocolNum 3
            in MiniProtocol {
                miniProtocolNum,
                miniProtocolLimits = Mux.MiniProtocolLimits maxBound,
                miniProtocolRun =
                  reqRespInitiatorAndResponder
                    (Mux.MiniProtocolNum 3)
                    responderAccumulatorFn
                    establishedAccumulatorVar
                    establishedRequestsVar
              }
          ]
      }

    reqRespInitiatorAndResponder
      :: Mux.MiniProtocolNum
      -> Fun (acc, req) (acc, resp)
      -> StrictTVar m acc
      -> StrictTVar m [[req]]
      -> RunMiniProtocol InitiatorResponderMode ByteString m [resp] acc
    reqRespInitiatorAndResponder protocolNum fn accumulatorVar requestsVar =
      InitiatorAndResponderProtocol
        (MuxPeer
          ((localAddress,"Initiator",protocolNum,) `contramap` nullTracer) -- TraceSendRecv
          codecReqResp
          (Effect $ do
            reqs <-
              atomically $ do
                requests <- readTVar requestsVar
                case requests of
                  (reqs : rest) -> do
                    writeTVar requestsVar rest $> reqs
                  [] -> pure []
            pure $ 
              reqRespClientPeer
              (reqRespClientMap reqs)))
        (MuxPeer
          ((localAddress,"Responder",protocolNum,) `contramap` nullTracer) -- TraceSendRecv
          codecReqResp
          (Effect $ reqRespServerPeer <$> reqRespServerMapAccumL' accumulatorVar (applyFun2 fn)))

    reqRespServerMapAccumL' :: StrictTVar m acc
                            -> (acc -> req -> (acc, resp))
                            -> m (ReqRespServer req resp m acc)
    reqRespServerMapAccumL' accumulatorVar fn = do
        acc <- atomically (readTVar accumulatorVar)
        pure $ go acc
      where
        go acc =
          ReqRespServer {
              recvMsgReq = \req -> case fn acc req of
                (acc', resp) -> pure (resp, go acc'),
              recvMsgDone = do
                atomically $ writeTVar accumulatorVar acc
                pure acc
            }




-- | Run all initiator mini-protocols and collect results. Throw exception if
-- any of the thread returned an exception.
--
runInitiatorProtocols
    :: forall muxMode m a b.
       ( MonadAsync      m
       , MonadCatch      m
       , MonadSTM        m
       , MonadThrow (STM m)
       , HasInitiator muxMode ~ True
       )
    => SingInitiatorResponderMode muxMode
    -> Mux.Mux muxMode m
    -> MuxBundle muxMode ByteString m a b
    -> m (Bundle [a])
runInitiatorProtocols singMuxMode mux (Bundle (WithHot hotPtcls) (WithWarm warmPtcls) (WithEstablished establishedPtcls)) = do
      -- start all protocols
      hotSTMs <- traverse runInitiator hotPtcls
      warmSTMs <- traverse runInitiator warmPtcls
      establishedSTMs <- traverse runInitiator establishedPtcls

      -- await for their termination
      hotRes <- traverse atomically hotSTMs
      warmRes <- traverse atomically warmSTMs
      establishedRes <- traverse atomically establishedSTMs
      case (partitionEithers hotRes, partitionEithers warmRes, partitionEithers establishedRes) of
        ((err : _, _), _, _) -> throwIO err
        (_, (err : _, _), _) -> throwIO err
        (_, _, (err : _, _)) -> throwIO err
        (([], hot), ([], warm), ([], established)) ->
          pure $ Bundle (WithHot hot) (WithWarm warm) (WithEstablished established)
  where
    runInitiator :: MiniProtocol muxMode ByteString m a b
                 -> m (STM m (Either SomeException a))
    runInitiator ptcl =
      Mux.runMiniProtocol
        mux
        (miniProtocolNum ptcl)
        (case singMuxMode of
          SInitiatorMode -> Mux.InitiatorDirectionOnly
          SInitiatorResponderMode -> Mux.InitiatorDirection)
        Mux.StartEagerly
        (runMuxPeer
          (case miniProtocolRun ptcl of
            InitiatorProtocolOnly initiator -> initiator
            InitiatorAndResponderProtocol initiator _ -> initiator)
          . fromChannel)


--
-- Experiments \/ Demos & Properties
--


-- | This test runs an intiator only connection manager (client side) and bidrectional
-- connection manager (which runs a server).   The the client connect to the
-- server and runs protocols to completion.
--
-- There is a good reason why we don't run two bidrectional connection managers;
-- If we would do that, when the either side terminates the connection the
-- client side server would through an exception as it is listening.
--
unidirectionalExperiment
    :: forall peerAddr socket acc req resp m.
       ( ConnectionManagerMonad m
       , MonadSay m

       , Ord peerAddr, Show peerAddr, Typeable peerAddr, Eq peerAddr
       , Serialise req, Show req
       , Serialise resp, Show resp, Eq resp
       , Typeable req, Typeable resp
       )
    => Snocket m socket peerAddr
    -> socket
    -> ClientAndServerData req resp acc
    -> m Property
unidirectionalExperiment snocket socket clientAndServerData = do
    withInitiatorOnlyConnectionManager
      "client" snocket clientAndServerData
      $ \connectionManager ->
        withBidirectionalConnectionManager
          "server" snocket socket Nothing clientAndServerData
          $ \_ serverAddr -> do
            -- client → server: connect
            muxHandle <- includeOutboundConnection connectionManager serverAddr
            case muxHandle of
                Connected _ (Handle mux muxBundle _) -> do
                    ( resp0 :: Bundle [[resp]]) <-
                      fold <$> replicateM (numberOfRounds clientAndServerData)
                                          (runInitiatorProtocols SInitiatorMode mux muxBundle)
                    pure $
                      (concat <$> resp0) === expectedResult
                                              clientAndServerData
                                              clientAndServerData


                Disconnected {} -> pure $ counterexample "mux failed" False


prop_unidirectional_IO
    :: ClientAndServerData Int Int Int
    -> Property
prop_unidirectional_IO clientAndServerData =
    ioProperty $ do
      -- threadDelay (0.100)
      withIOManager $ \iomgr ->
        bracket
          (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol)
          Socket.close
          $ \socket -> do
              associateWithIOManager iomgr (Right socket)
              addr <- head <$> Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just "0")
              Socket.bind socket (Socket.addrAddress addr)
              Socket.listen socket maxBound
              unidirectionalExperiment
                (socketSnocket iomgr)
                socket
                clientAndServerData


-- | Bidirectional send and receive.
--
bidirectionalExperiment
    :: forall peerAddr socket acc req resp m.
       ( ConnectionManagerMonad m
       , MonadSay m

       , Ord peerAddr, Show peerAddr, Typeable peerAddr, Eq peerAddr

       , Serialise req, Show req
       , Serialise resp, Show resp, Eq resp
       , Typeable req, Typeable resp
       , Show acc
       )
    => Snocket m socket peerAddr
    -> socket
    -> socket
    -> peerAddr
    -> peerAddr
    -> ClientAndServerData req resp acc
    -> ClientAndServerData req resp acc
    -> m Property
bidirectionalExperiment
    snocket socket0 socket1 localAddr0 localAddr1
    clientAndServerData0 clientAndServerData1 = do
      withBidirectionalConnectionManager
        "node-0" snocket socket0 (Just localAddr0) clientAndServerData0
        (\connectionManager0 _serverAddr0 ->
          withBidirectionalConnectionManager
            "node-1" snocket socket1 (Just localAddr1) clientAndServerData1
            (\connectionManager1 _serverAddr1 -> do
              -- node 0 → node 1: connect
              connected0 <- includeOutboundConnection connectionManager0 localAddr1
              -- node 1 → node 0: reuse existing connection
              connected1 <- includeOutboundConnection connectionManager1 localAddr0
              case (connected0, connected1) of
                  ( Connected connId0 (Handle mux0 muxBundle0 _)
                    , Connected connId1 (Handle mux1 muxBundle1 _) ) -> do
                      -- runInitiatorProtcols returns a list of results per each
                      -- protocol in each bucket (warm \/ hot \/ established); but
                      -- we run only one mini-protocol. We can use `concat` to
                      -- flatten the results.
                      ( resp0 :: Bundle [[resp]]
                        , resp1 :: Bundle [[resp]]
                        ) <-
                        -- Run initiator twice; this tests if the responders on
                        -- the other end are restarted.
                        (fold <$> replicateM (numberOfRounds clientAndServerData0)
                                     (runInitiatorProtocols SInitiatorResponderMode mux0 muxBundle0))
                        `concurrently`
                        (fold <$> replicateM (numberOfRounds clientAndServerData1)
                                     (runInitiatorProtocols SInitiatorResponderMode mux1 muxBundle1))
                      pure $
                        counterexample "0"
                          ((concat <$> resp0) === expectedResult clientAndServerData0
                                                                 clientAndServerData1)
                        .&&.
                        counterexample "1"
                          ((concat <$> resp1) === expectedResult clientAndServerData1
                                                                 clientAndServerData0)
                        .&&.
                        -- check weather we reused the connection
                        connId0 === flipConnectionId connId1
                  _ -> pure $ counterexample "mux failed" False
              ))
  where
    flipConnectionId :: ConnectionId peerAddr -> ConnectionId peerAddr
    flipConnectionId ConnectionId {localAddress, remoteAddress}
      = ConnectionId {
          localAddress = remoteAddress,
          remoteAddress = localAddress
        }


prop_bidirectional_IO
    :: ClientAndServerData Int Int Int
    -> ClientAndServerData Int Int Int
    -> Property
prop_bidirectional_IO data0 data1 =
    ioProperty $ do
      withIOManager $ \iomgr ->
        bracket
          ((,)
            <$> Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
            <*> Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol)
          (\(socket0,socket1) -> Socket.close socket0
                              >> Socket.close socket1)
          $ \(socket0, socket1) -> do
            associateWithIOManager iomgr (Right socket0)
            associateWithIOManager iomgr (Right socket1)
            Socket.setSocketOption socket0 Socket.ReuseAddr 1
            Socket.setSocketOption socket1 Socket.ReuseAddr 1
#if !defined(mingw32_HOST_OS)
            Socket.setSocketOption socket0 Socket.ReusePort 1
            Socket.setSocketOption socket1 Socket.ReusePort 1
#endif
            addr <- head <$> Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just "0")
            Socket.bind socket0 (Socket.addrAddress addr)
            Socket.listen socket0 maxBound
            Socket.bind socket1 (Socket.addrAddress addr)
            Socket.listen socket1 maxBound
            localAddr0 <- Socket.getSocketName socket0
            localAddr1 <- Socket.getSocketName socket1
            -- we need to make a dance with addresses; when a connection is
            -- accepted the remote `Socket.SockAddr` will be `127.0.0.1:port`
            -- rather than `0.0.0.0:port`.  If we pass `0.0.0.0:port` the
            -- then the connection would not be found by the connection manager
            -- and creating a socket would fail as we would try to create
            -- a connection with the same quadruple as an existing connection.
            let localAddr0' = case localAddr0 of
                  Socket.SockAddrInet port _ ->
                    Socket.SockAddrInet port (Socket.tupleToHostAddress (127,0,0,1))
                  _ -> error "unexpected address"

                localAddr1' = case localAddr1 of
                  Socket.SockAddrInet port _ ->
                    Socket.SockAddrInet port (Socket.tupleToHostAddress (127,0,0,1))
                  _ -> error "unexpected address"

            bidirectionalExperiment
              (socketSnocket iomgr)
              socket0     socket1
              localAddr0' localAddr1'
              data0       data1


--
-- Utils
--

debugTracer :: (MonadSay m, Show a) => Tracer m a
debugTracer = Tracer (say . show)


connectionManagerTracer :: (MonadSay m, Show peerAddr, Show a)
         => Tracer m (String, ConnectionManagerTrace peerAddr a)
connectionManagerTracer =
    Tracer
      $ \msg ->
        case msg of
          (_, TrConnectError{})
            -> -- this way 'debugTracer' does not trigger a warning :)
              traceWith debugTracer msg
          (_, _) ->
              pure ()
