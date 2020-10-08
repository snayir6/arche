{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE TypeOperators       #-}

module Handler.ORAPI
  ( orApi
  , getOR
  ) where

import Control.Lens                 ((&), (.~), (?~), view)
import Control.Monad                (void)
import Control.Monad.Trans.Resource (liftResourceT)
import Control.Monad.IO.Class       (liftIO)
import Data.Conduit                 (runConduit, (.|))
import Data.Maybe                   (mapMaybe)
import Network.HTTP.Conduit         (RequestBody(..))
import Network.HTTP.Media.MediaType ((//))

import qualified Data.Conduit.Binary      as Conduit
import qualified Network.Google           as Google
import qualified Network.Google.FireStore as FireStore
import qualified Network.Google.Storage   as Storage
import Servant

import Data.VTK (renderUniVTK)

import qualified Arche.Strategy.ORFitAll as OR

import Type.API
import Type.Storage
import Type.Store
import Util.FireStore
import Util.Hash
import Util.Logger    (logGGInfo, logMsg)

import qualified Util.Auth   as Auth
import qualified Util.Client as Client
import qualified Util.Tasks  as SelfTasks

--type ORAPI = "ebsd" :> Capture "hash" HashEBSD :> "orfit" :>
--  (                              Get  '[JSON] [OR]
--  :<|> Capture "hash" HashOR  :> Get  '[JSON] OR
--  :<|> ReqBody '[JSON] OR.Cfg :> Post '[JSON] NoContent
--  )

orApi :: Auth.BearerToken -> User -> Server ORAPI
orApi tk user = \hashebsd ->
       (runGCPWith $ addHeader private15sCache <$> getORs hashebsd)
  :<|> (runGCPWith . getOR user hashebsd)
  :<|> (\cfg -> runGCPWith $ runORFitHandler hashebsd cfg ebsdBucket)
  :<|> (\cfg -> runGCPWith $ runAsyncORFitHandler tk hashebsd cfg)
  where
    private15sCache = "private, max-age=15, s-maxage=15" :: String

runAsyncORFitHandler :: Auth.BearerToken -> HashEBSD -> OR.Cfg -> Google.Google GCP HashOR
runAsyncORFitHandler tk hashE orCfg = let
  archeapi = (Client.orApiClient Client.mkApiClient) hashE
  hashO    = calculateHashOR orCfg
  in do
    _ <- SelfTasks.submitSelfTask orFitQueue tk ((Client.postOR archeapi) orCfg)
    return hashO

runORFitHandler :: HashEBSD -> OR.Cfg -> StorageBucket -> Google.Google GCP OR
runORFitHandler hashebsd@(HashEBSD hash) cfg bucket = do
  let bucketName = bktName bucket
  stream <- Google.download (Storage.objectsGet bucketName hash)
  ang    <- liftResourceT (runConduit (stream .| Conduit.sinkLbs))

  -- Force strictness on OR calculation otherwise the data
  --upload bellow can timeout while awaiting for calculation.
  (!orEval, vtk) <- liftIO $ OR.processEBSD cfg ang

  let
    body = Google.GBody ("application" // "octet-stream") (RequestBodyLBS $ renderUniVTK True vtk)
    vox_key = hash <> ".vtk"
  
  void $ Google.upload (Storage.objectsInsert bucketName Storage.object' & Storage.oiName ?~ vox_key) body

  let orship = OR
         { hashOR   = calculateHashOR cfg
         , cfgOR    = cfg
         , resultOR = orEval
         }
  
  writeOR hashebsd orship 

  return orship

writeOR :: HashEBSD -> OR -> Google.Google GCP ()
writeOR (HashEBSD hashE) orValue  = do
    let
      HashOR hashO = hashOR orValue
      path = "projects/apt-muse-269419/databases/(default)/documents/ebsd/" <> hashE <> "/or/" <> hashO
    void $ Google.send (FireStore.projectsDatabasesDocumentsPatch (toDoc orValue) path)

getOR :: User -> HashEBSD -> HashOR -> Google.Google GCP OR
getOR user (HashEBSD hashEbsd) (HashOR hashOr) = do
  logGGInfo $ logMsg ("Retriving OR" :: String) hashOr ("for user" :: String) (id_number user)
  let path = "projects/apt-muse-269419/databases/(default)/documents/ebsd/" <> hashEbsd <> "/or/" <> hashOr
  resp <- Google.send (FireStore.projectsDatabasesDocumentsGet path)
  let orDoc = either error id (fromDoc resp)
  return orDoc

getORs :: (FromDocValue a) => HashEBSD -> Google.Google GCP [a]
getORs (HashEBSD hashE) = do
  let
    db = "projects/apt-muse-269419/databases/(default)/documents/ebsd/" <> hashE
    
    query :: FireStore.StructuredQuery
    query = let
      from = FireStore.collectionSelector &
        FireStore.csCollectionId ?~ "or" &
        FireStore.csAllDescendants ?~ False
      in FireStore.structuredQuery
        & FireStore.sqFrom .~ [from] 
    
    commitReq :: FireStore.RunQueryRequest
    commitReq = FireStore.runQueryRequest & FireStore.rqrStructuredQuery ?~ query

  logGGInfo $ logMsg ("Retriving ORs for EBSD" :: String) hashE
  resp <- Google.send (FireStore.projectsDatabasesDocumentsRunQuery db commitReq)
  return . mapMaybe (fmap (either error id . fromDoc) . view FireStore.rDocument) $ resp
