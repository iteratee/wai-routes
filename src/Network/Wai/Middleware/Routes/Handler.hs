{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving, CPP #-}
{- |
Module      :  Network.Wai.Middleware.Routes.Handler
Copyright   :  (c) Anupam Jain 2013
License     :  MIT (see the file LICENSE)

Maintainer  :  ajnsit@gmail.com
Stability   :  experimental
Portability :  non-portable (uses ghc extensions)

Provides a HandlerM Monad that makes it easy to build Handlers
-}
module Network.Wai.Middleware.Routes.Handler
    ( HandlerM()             -- | A Monad that makes it easier to build a Handler
    , runHandlerM            -- | Run a HandlerM to get a Handler
    , request                -- | Access the request data
    , reqHeader              -- | Get a particular request header (case insensitive)
    , reqHeaders             -- | Get all request headers (case insensitive)
    , routeAttrSet           -- | Access the route attribute list
    , rootRouteAttrSet       -- | Access the route attribute list for the root route
    , maybeRoute             -- | Access the route data
    , maybeRootRoute         -- | Access the root route data
    , showRouteMaster        -- | Get the route rendering function for the master site
    , showRouteSub           -- | Get the route rendering function for the subsite
    , showRouteQueryMaster   -- | Get the route + query params rendering function for the master site
    , showRouteQuerySub      -- | Get the route + query params rendering function for the subsite
    , readRouteMaster        -- | Get the route parsing function for the master site
    , readRouteSub           -- | Get the route parsing function for the subsite
    , master                 -- | Access the master datatype
    , header                 -- | Add a header to the response
    , status                 -- | Set the response status
    , file                   -- | Send a file as response
    , stream                 -- | Stream a response
    , raw                    -- | Set the raw response body
    , json                   -- | Set the json response body
    , plain                  -- | Set the plain text response body
    , html                   -- | Set the html response body
    , css                    -- | Set the css response body
    , javascript             -- | Set the javascript response body
    , asContent              -- | Set the contentType and a 'Text' body
    , next                   -- | Run the next application in the stack
    , rawBody                -- | Consume and return the request body as a lazy bytestring
    , jsonBody               -- | Consume and return the request body as JSON
    )
    where

import Network.Wai (Request, Response, responseFile, responseBuilder, responseStream, pathInfo, queryString, requestBody, StreamingBody, requestHeaders)
#if MIN_VERSION_wai(3,0,1)
import Network.Wai (strictRequestBody)
#endif
import Network.Wai.Middleware.Routes.Routes (Env(..), RequestData, HandlerS, waiReq, currentRoute, runNext, ResponseHandler, showRoute, showRouteQuery, readRoute)
import Network.Wai.Middleware.Routes.Class (Route, RenderRoute, ParseRoute, RouteAttrs(..))
import Network.Wai.Middleware.Routes.ContentTypes (contentType, typeHtml, typeJson, typePlain, typeCss, typeJavascript)

import Control.Monad (liftM)
import Control.Monad.Loops (unfoldWhileM)
import Control.Monad.State (StateT, get, put, modify, runStateT, MonadState, MonadIO, lift, liftIO, MonadTrans)

import Control.Applicative (Applicative, (<$>))

import Data.Maybe (maybe)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Blaze.ByteString.Builder (fromLazyByteString)
import Network.HTTP.Types.Header (HeaderName(), RequestHeaders)
import Network.HTTP.Types.Status (Status(), status200)

import Data.Aeson (ToJSON, FromJSON, eitherDecode)
import qualified Data.Aeson as A

import Data.Set (Set)
import qualified Data.Set as S (empty, map)

import Data.Text.Lazy (Text)
import qualified Data.Text as TS (Text)
import qualified Data.Text.Lazy as T
import Data.Text.Lazy.Encoding (encodeUtf8)
import Data.Text.Encoding (decodeUtf8)

import Data.CaseInsensitive (mk)


-- | The internal implementation of the HandlerM monad
-- TODO: Should change this to StateT over ReaderT (but performance may suffer)
newtype HandlerMI sub master m a = H { extractH :: StateT (HandlerState sub master) m a }
    deriving (Applicative, Monad, MonadIO, Functor, MonadTrans, MonadState (HandlerState sub master))

-- | The HandlerM Monad
type HandlerM sub master a = HandlerMI sub master IO a

-- | The state kept in a HandlerM Monad
data HandlerState sub master = HandlerState
                { getMaster      :: master
                , getRequestData :: RequestData sub
                -- TODO: Experimental
                -- Streaming request body, consumed, and stored as a ByteString
                , reqBody        :: Maybe BL.ByteString
                , respHeaders    :: [(HeaderName, ByteString)]
                , respStatus     :: Status
                , respResp       :: Maybe ResponseHandler
                , getSub         :: sub
                , toMasterRoute  :: Route sub -> Route master
                }

-- | "Run" HandlerM, resulting in a Handler
runHandlerM :: HandlerM sub master () -> HandlerS sub master
runHandlerM h env req hh = do
  (_, st) <- runStateT (extractH h) (HandlerState (envMaster env) req Nothing [] status200 Nothing (envSub env) (envToMaster env))
  case respResp st of
    -- Experimental, if you don't respond in one handler, move to next automatically
    Nothing -> runNext (getRequestData st) hh
    Just resp -> resp hh

-- | Get the request body as a lazy bytestring. However consumes the entire body at once.
-- TODO: Implement streaming. Prevent clash with direct use of `Network.Wai.requestBody`
rawBody :: HandlerM master master BL.ByteString
rawBody = do
  s <- get
  case reqBody s of
    Just consumedBody -> return consumedBody
    Nothing -> do
      req <- request
      rbody <- liftIO $ readStrictRequestBody req
      put s {reqBody = Just rbody}
      return rbody

readStrictRequestBody :: Request -> IO BL.ByteString
readStrictRequestBody =
#if MIN_VERSION_wai(3,0,1)
        -- Use the `strictRequestBody` function available in wai > 3.0.1
        strictRequestBody
#else
        -- Consume the entire body, and cache
        BL.fromChunks <$> unfoldWhileM (not . B.null) . requestBody
#endif

-- | Parse the body as a JSON object
jsonBody :: FromJSON a => HandlerM master master (Either String a)
jsonBody = liftM eitherDecode rawBody

-- | Get the master
master :: HandlerM sub master master
master = liftM getMaster get

-- | Get the sub
sub :: HandlerM sub master sub
sub = liftM getSub get

-- | Get the request
request :: HandlerM sub master Request
request = liftM (waiReq . getRequestData) get

-- | Get a particular request header (Case insensitive)
reqHeader :: ByteString -> HandlerM sub master (Maybe ByteString)
reqHeader name = liftM (lookup $ mk name) reqHeaders

-- | Get all request headers (Case insensitive)
reqHeaders :: HandlerM sub master RequestHeaders
reqHeaders = liftM requestHeaders request

-- | Get the current route
maybeRoute :: HandlerM sub master (Maybe (Route sub))
maybeRoute = liftM (currentRoute . getRequestData) get

-- | Get the current root route
maybeRootRoute :: HandlerM sub master (Maybe (Route master))
maybeRootRoute = do
  s <- get
  return $ fmap (toMasterRoute s) $ currentRoute $ getRequestData s

-- | Get the route rendering function for the master site
showRouteMaster :: RenderRoute master => HandlerM sub master (Route master -> TS.Text)
showRouteMaster = return showRoute

-- | Get the route rendering function for the subsite
showRouteSub :: RenderRoute master => HandlerM sub master (Route sub -> TS.Text)
showRouteSub = do
  s <- get
  return $ showRoute . toMasterRoute s

-- | Get the route rendering function for the master site
showRouteQueryMaster :: RenderRoute master => HandlerM sub master (Route master -> [(TS.Text,TS.Text)] -> TS.Text)
showRouteQueryMaster = return showRouteQuery

-- | Get the route rendering function for the subsite
showRouteQuerySub :: RenderRoute master => HandlerM sub master (Route sub -> [(TS.Text,TS.Text)] -> TS.Text)
showRouteQuerySub = do
  s <- get
  return $ showRouteQuery . toMasterRoute s

-- | Get the route parsing function for the master site
readRouteMaster :: ParseRoute master => HandlerM sub master (TS.Text -> Maybe (Route master))
readRouteMaster = return readRoute

-- | Get the route parsing function for the subsite
readRouteSub :: ParseRoute sub => HandlerM sub master (TS.Text -> Maybe (Route master))
readRouteSub = do
  s <- get
  return $ fmap (toMasterRoute s) . readRoute

-- | Get the current route attributes
routeAttrSet :: RouteAttrs sub => HandlerM sub master (Set Text)
routeAttrSet = liftM (S.map T.fromStrict . maybe S.empty routeAttrs . currentRoute . getRequestData) get

-- | Get the attributes for the current root route
rootRouteAttrSet :: RouteAttrs master => HandlerM sub master (Set Text)
rootRouteAttrSet = do
  s <- get
  return $ S.map T.fromStrict $ maybe S.empty (routeAttrs . toMasterRoute s) $ currentRoute $ getRequestData s

-- | Add a header to the application response
-- TODO: Differentiate between setting and adding headers
header :: HeaderName -> ByteString -> HandlerM sub master ()
header h s = modify $ addHeader h s
  where
    addHeader :: HeaderName -> ByteString -> HandlerState sub master -> HandlerState sub master
    addHeader h b s@(HandlerState {respHeaders=hs}) = s {respHeaders=(h,b):hs}

-- | Set the response status
status :: Status -> HandlerM sub master ()
status s = modify $ setStatus s
  where
    setStatus :: Status -> HandlerState sub master -> HandlerState sub master
    setStatus s st = st{respStatus=s}

-- | Set the response body to a file
file :: FilePath -> HandlerM sub master ()
file f = modify addFile
  where
    addFile st = _setResp st $ responseFile (respStatus st) (respHeaders st) f Nothing

-- | Stream the response
stream :: StreamingBody -> HandlerM sub master ()
stream s = modify addStream
  where
    addStream st = _setResp st $ responseStream (respStatus st) (respHeaders st) s

-- | Set the response body
raw :: BL.ByteString -> HandlerM sub master ()
raw bs = modify addBody
  where
    addBody st = _setResp st $ responseBuilder (respStatus st) (respHeaders st) (fromLazyByteString bs)

-- | Run the next application
next :: HandlerM sub master ()
next = do
  respHandler <- liftM (runNext . getRequestData) get
  modify $ _setRespHandler respHandler

-- Util
-- Set the response directly
-- This is a bit convulated to enable clean usage in calling functions
_setResp :: HandlerState sub master -> Response -> HandlerState sub master
_setResp st r = _setRespHandler ($ r) st

-- Util
-- Set the response handler
-- Don't overwrite previous response handler
_setRespHandler :: ResponseHandler -> HandlerState sub master -> HandlerState sub master
_setRespHandler r st = case respResp st of
  Just _ -> st
  Nothing -> st{respResp=Just r}

-- Standard response bodies

-- | Set the body of the response to the JSON encoding of the given value. Also sets \"Content-Type\"
-- header to \"application/json\".
json :: ToJSON a => a -> HandlerM sub master ()
json a = do
  header contentType typeJson
  raw $ A.encode a

-- | Set the body of the response to the given 'Text' value. Also sets \"Content-Type\"
-- header to \"text/plain\".
plain :: Text -> HandlerM sub master ()
plain = asContent typePlain

-- | Set the body of the response to the given 'Text' value. Also sets \"Content-Type\"
-- header to \"text/html\".
html :: Text -> HandlerM sub master ()
html = asContent typeHtml

-- | Set the body of the response to the given 'Text' value. Also sets \"Content-Type\"
-- header to \"text/css\".
css :: Text -> HandlerM sub master ()
css = asContent typeCss

-- | Set the body of the response to the given 'Text' value. Also sets \"Content-Type\"
-- header to \"text/javascript\".
javascript :: Text -> HandlerM sub master ()
javascript = asContent typeJavascript

-- | Sets the content-type header to the given Bytestring
--  (look in Network.Wai.Middleware.Routes.ContentTypes for examples)
--  And sets the body of the response to the given Text
asContent :: ByteString -> Text -> HandlerM sub master ()
asContent ctype content = do
  header contentType ctype
  raw $ encodeUtf8 content

