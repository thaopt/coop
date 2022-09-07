{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module Main (main) where

import BotPlutusInterface.Types (LogContext (ContractLog), LogLevel (Info))
import Control.Lens ((^.))
import Control.Monad.Reader (ReaderT)
import Coop.Pab (burnCerts, deployAuth, deployCoop, findOutsAtCertVWithCERT, findOutsAtHoldingAa, mintAuth, mintCert, mintCertRedeemers)
import Coop.Pab.Aux (DeployMode (DEPLOY_DEBUG), ciValueOf, findOutsAtHolding, loadCoopPlutus, makeCollateralOuts, mintNft, testDataRoundtrip, testDataRoundtrip')
import Coop.Types (AuthDeployment (ad'authorityAc), CertDatum (CertDatum), CoopDeployment (cd'auth), CoopPlutus (cp'certV, cp'mkNftMp))
import Data.Bifunctor (Bifunctor (second))
import Data.Bool (bool)
import Data.Default (def)
import Data.Foldable (Foldable (toList))
import Data.List.NonEmpty (NonEmpty)
import GHC.Natural (Natural)
import Ledger (Validator (Validator), ciTxOutValue, interval)
import Ledger.Value (AssetClass (unAssetClass), assetClass, currencySymbol, tokenName, valueOf)
import Plutus.Contract (currentTime, logInfo, ownFirstPaymentPubKeyHash, throwError, waitNSlots)
import Test.Plutip.Contract (TestWallets, assertExecutionWith, initAda, withContract, withContractAs)
import Test.Plutip.Internal.Types (ClusterEnv, ExecutionResult (outcome))
import Test.Plutip.LocalCluster (BpiWallet, withConfiguredCluster)
import Test.Plutip.Options (TraceOption (ShowBudgets, ShowTraceButOnlyContext))
import Test.Plutip.Predicate (shouldSucceed, shouldYield)
import Test.Tasty (DependencyType (AllFinish), TestName, TestTree, after, defaultMain)

main :: IO ()
main = do
  coopPlutus <- loadCoopPlutus DEPLOY_DEBUG
  defaultMain (tests coopPlutus)

slotsToWait :: Natural
slotsToWait = 40

testOpts :: [TraceOption]
testOpts = [ShowTraceButOnlyContext ContractLog Info, ShowBudgets]

tests :: CoopPlutus -> TestTree
tests coopPlutus =
  withConfiguredCluster
    def
    "coop-pab-tests"
    [ assertExecutionWith
        testOpts
        "datum-roundtrip"
        (initAda [100])
        ( withContract @String
            ( const $ do
                _ <- waitNSlots slotsToWait
                let validityInterval = interval 0 100_000
                    x = CertDatum "" validityInterval (assetClass (currencySymbol "") (tokenName ""))
                if testDataRoundtrip' x
                  then do
                    testDataRoundtrip (Validator . cp'certV $ coopPlutus) x
                  else do
                    throwError "Pure roundtrip failed"
            )
        )
        [shouldSucceed]
    , assertExecutionWith
        testOpts
        "mint-nft"
        (initAda [100] <> initAda [100])
        ( withContract @String
            ( \[nftWallet] -> do
                self <- ownFirstPaymentPubKeyHash
                _ <- waitNSlots slotsToWait
                (_, (nftAc, _)) <- mintNft self nftWallet (cp'mkNftMp coopPlutus) 1
                _ <- waitNSlots slotsToWait
                found <- findOutsAtHolding nftWallet nftAc
                return $ length found
            )
        )
        [shouldSucceed, shouldYield 1]
    , runAfter "mint-nft" $
        assertExecutionWith
          testOpts
          "deploy-authentication"
          (initAda [100] <> initAda [100])
          ( withContract @String
              ( \[aaWallet] -> do
                  logInfo @String "Running as godWallet"
                  self <- ownFirstPaymentPubKeyHash
                  _ <- waitNSlots slotsToWait
                  authDeployment <- deployAuth coopPlutus self aaWallet 3
                  _ <- waitNSlots slotsToWait
                  aaOuts <- findOutsAtHolding aaWallet (ad'authorityAc authDeployment)
                  let (aaCs, aaTn) = unAssetClass . ad'authorityAc $ authDeployment
                  return $ [valueOf (out ^. ciTxOutValue) aaCs aaTn | out <- toList aaOuts]
              )
          )
          [shouldSucceed, shouldYield [3]]
    , runAfter "deploy-authentication" $
        assertExecutionWith
          testOpts
          "deploy-coop"
          (initAda [200] <> initAda [200])
          ( withContract @String
              ( \[aaWallet] -> do
                  logInfo @String "Running as godWallet"
                  self <- ownFirstPaymentPubKeyHash
                  _ <- makeCollateralOuts self 5 20_000_000
                  _ <- waitNSlots slotsToWait
                  coopDeployment <- deployCoop coopPlutus self aaWallet 3
                  _ <- waitNSlots slotsToWait
                  aaOuts <- findOutsAtHoldingAa aaWallet coopDeployment
                  return $ [ciValueOf (ad'authorityAc . cd'auth $ coopDeployment) out | out <- toList aaOuts]
              )
          )
          [shouldSucceed, shouldYield [3]]
    , runAfter "deploy-coop" $
        assertExecutionWith
          testOpts
          "mint-cert"
          (initAda [200] <> initAda [200] <> initAda [200])
          ( do
              (coopDeployment, certRedeemerAc) <- godDeploysCoop coopPlutus

              _ <-
                withContractAs @String
                  1
                  ( \_ -> do
                      logInfo @String "Running as aaWallet"
                      self <- ownFirstPaymentPubKeyHash
                      aaOuts <- findOutsAtHoldingAa self coopDeployment
                      _ <- waitNSlots slotsToWait
                      now <- currentTime
                      let validityInterval = interval now (now + 100_000)
                      _ <- mintCert certRedeemerAc validityInterval aaOuts coopDeployment
                      waitNSlots slotsToWait
                  )
              withContract @String
                ( \_ -> do
                    certOuts <- findOutsAtCertVWithCERT coopDeployment
                    logInfo $ "Found " <> (show . length $ certOuts) <> " $CERT outputs"
                    bool (throwError "There should be some $CERT inputs") (pure ()) $ not (null certOuts)
                    waitNSlots slotsToWait
                )
          )
          [shouldSucceed]
    , runAfter "mint-cert" $
        assertExecutionWith
          testOpts
          "burn-cert"
          (initAda [200] <> initAda [200] <> initAda [200])
          ( do
              (coopDeployment, certRedeemerAc) <- godDeploysCoop coopPlutus

              _ <-
                withContractAs @String
                  1
                  ( \[_, _] -> do
                      logInfo @String "Running as aaWallet"
                      self <- ownFirstPaymentPubKeyHash
                      aaOuts <- findOutsAtHoldingAa self coopDeployment
                      _ <- waitNSlots slotsToWait
                      now <- currentTime
                      let validityInterval = interval now (now + 100_000)
                      _ <- mintCert certRedeemerAc validityInterval aaOuts coopDeployment
                      waitNSlots slotsToWait
                  )

              withContractAs @String
                2
                ( \[_, _] -> do
                    logInfo @String "Running as certRedeemerWallet"
                    self <- ownFirstPaymentPubKeyHash
                    certRedeemerOuts <- findOutsAtHolding self certRedeemerAc
                    certOuts <- findOutsAtCertVWithCERT coopDeployment
                    logInfo $ "Found " <> (show . length $ certOuts) <> " $CERT outputs"
                    bool
                      (throwError "There should be some $CERT inputs")
                      (logInfo @String $ "Found " <> (show . length $ certOuts) <> " $CERT inputs")
                      $ not (null certOuts)
                    _ <- burnCerts certOuts certRedeemerOuts coopDeployment
                    waitNSlots slotsToWait
                )
          )
          [shouldSucceed]
    , runAfter "burn-cert" $
        assertExecutionWith
          testOpts
          "mint-auth"
          (initAda [200] <> initAda [200] <> initAda [200] <> initAda [200] <> initAda [200]) -- TODO: Make this more explicit somehow
          ( do
              (coopDeployment, _) <- godDeploysCoop coopPlutus

              withContractAs @String
                1
                ( \[_, _, authWalletGeorge, authWalletPeter] -> do
                    logInfo @String "Running as aaWallet"
                    self <- ownFirstPaymentPubKeyHash
                    aaOuts <- findOutsAtHoldingAa self coopDeployment
                    _ <- waitNSlots slotsToWait
                    (_, authAc) <- mintAuth self [authWalletGeorge, authWalletPeter] 10 aaOuts coopDeployment
                    _ <- waitNSlots slotsToWait
                    georgesOuts <- findOutsAtHolding authWalletGeorge authAc
                    petersOuts <- findOutsAtHolding authWalletPeter authAc
                    return $
                      [ciValueOf authAc out | out <- toList georgesOuts]
                        <> [ciValueOf authAc out | out <- toList petersOuts]
                )
          )
          [shouldSucceed, shouldYield [10, 10]]
    ]

runAfter ::
  TestName ->
  (TestWallets, IO (ClusterEnv, NonEmpty BpiWallet) -> TestTree) ->
  (TestWallets, IO (ClusterEnv, NonEmpty BpiWallet) -> TestTree)
runAfter testName = second (fmap . after AllFinish $ '/' : testName ++ "/")

godDeploysCoop :: CoopPlutus -> ReaderT (ClusterEnv, NonEmpty BpiWallet) IO (CoopDeployment, AssetClass)
godDeploysCoop coopPlutus = do
  res <-
    withContract @String
      ( \(aaWallet : certRedeemerWallet : _) -> do
          logInfo @String "Running as godWallet"
          self <- ownFirstPaymentPubKeyHash
          _ <- makeCollateralOuts self 5 20_000_000
          _ <- waitNSlots slotsToWait
          coopDeployment <- deployCoop coopPlutus self aaWallet 3
          _ <- waitNSlots slotsToWait
          (_, (certRedeemerAc, _)) <- mintCertRedeemers coopPlutus self certRedeemerWallet 100
          _ <- waitNSlots slotsToWait
          return (coopDeployment, certRedeemerAc)
      )
  either
    (fail . show)
    (\(res', _) -> pure res')
    $ outcome res
