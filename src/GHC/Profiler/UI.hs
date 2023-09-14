{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE LambdaCase #-}

-- | App web UI
module GHC.Profiler.UI
  ( httpApp
  , initUIState
  , UIState
  )
where

import GHC.Profiler.State
import GHC.Profiler.UI.Style
import GHC.Profiler.UI.Events

import Network.Wai
import Network.HTTP.Types.Status
import Lucid.Base
import Lucid.Html5
import Lucid.Htmx
import Data.Text.Lazy.Encoding (encodeUtf8)
import Control.Concurrent
import Control.Monad
import Data.IORef
import Data.Text (Text,pack,unpack)
import Data.ByteString.Builder
import System.Process
import System.FilePath
import System.IO.Temp
import System.Exit

------------------------------------
-- To upstream in lucid2-htmx
--
sseSwap_ :: Term arg result => arg -> result
sseSwap_ = term "sse-swap"

sseConnect_ :: Term arg result => arg -> result
sseConnect_ = term "sse-connect"

------------------------------------

data UIState = UIState
  { uiSSE      :: !SSE
  , uiAppState :: !S
  , uiGhcOut   :: !(IORef (Maybe (ExitCode,String,String))) -- Last GHC output
  , uiUnique   :: !(IORef Integer)                          -- ^ Unique counter
  }

initUIState :: S -> IO UIState
initUIState state = do
  -- Initialize global server-sent events
  sse <- initSSE
  -- TODO: we need to get events from somewhere.
  --  - add listener to events produced by the app (another Chan in State?)
  --  - poke State regularly?
  -- We don't want to have too much application logic in the UI in case we
  -- decide to have a TUI too.

  -- some empty value for last GHC result
  ghc_res <- newIORef Nothing

  uniq <- newIORef 0

  pure $ UIState
    { uiSSE      = sse
    , uiAppState = state
    , uiGhcOut   = ghc_res
    , uiUnique   = uniq
    }

-- | Get unique value
getUnique :: UIState -> IO Integer
getUnique s = atomicModifyIORef' (uiUnique s) \v -> (v+1,v)


httpApp :: UIState -> Application
httpApp state req respond = do

  let
    respondHtml' status headers html = do
      let bs = Lucid.Base.renderBS html
      respond (responseLBS status headers bs)

    respondHtml html = respondHtml' ok200 [] html
    respondLBS status headers bs = respond (responseLBS status headers bs)
    respondText status headers t = respondLBS status headers (encodeUtf8 t)

    sse = uiSSE state

  -- match on request and respond
  case pathInfo req of
    []            -> respondHtml (full state (welcomeHtml state))
    ["style.css"] -> respondText ok200 [] renderedCss
    ["events"]    -> respond =<< responseSSE sse

    "nav" : path  -> respondHtml $ navHtml True state (fmap (read . unpack) path)

    ["status"]    -> do
      readIORef (uiGhcOut state) >>= \case
        Nothing             -> respondHtml "No GHC result"
        Just (code,out,err) -> respondHtml do
          p_ [] do
            "GHC terminated with: "
            toHtml (show code)
          "Stdout:"
          pre_ [] (toHtml out)
          "Stderr:"
          pre_ [] (toHtml err)

    ["clicked"]   -> do
      -- TODO: don't spawn the thread twice...
      void $ forkIO $ withSystemTempDirectory "ghc-prof" \fp -> do
        let p = fp </> "HelloWorld.hs"
        Prelude.writeFile p
          "module Main where\n\
          \main :: IO ()\n\
          \main = putStrLn \"Hello World\""
        (code,out,err) <- readCreateProcessWithExitCode ((shell ("ghc " <> p <> " +RTS -s"))
          { cwd = Just fp
          })
          ""
        -- store result
        writeIORef (uiGhcOut state) (Just (code,out,err))
        -- signal that result arrived
        sendEvent sse $ ServerEvent
          { eventName = Just $ byteString "status_update"
          , eventId   = Nothing
          , eventData = [""]
          }
      respondHtml (clickedHtml state)

    _             -> respondLBS status404 [] ""


welcomeHtml :: UIState -> Html ()
welcomeHtml _state = do
  h1_ "Welcome to the GHC profiler (alpha)"
  p_ "The purpose of this profiler is twofold:"
  ul_ do
    li_ "Profiling and optimizing GHC itself"
    li_ "Profiling and optimizing programs built with GHC"

  p_ do
    "This tool allows you to perform several analyses directly from this interface. "
    "Use the navigation panel on the left to start producing and exploring profiling data. "

  p_ do
    "Bug reports and suggestions welcome at "
    a_ [ href_   "https://github.com/hsyl20/ghc-profiler/issues"
       , target_ "blank_"
       ]
       "https://github.com/hsyl20/ghc-profiler/issues"

  p_ "Happy profiling!"



clickedHtml :: UIState -> Html ()
clickedHtml _state = do
  div_
    [ id_ "dynamic"
    ] do
      div_
        [ 
        ] do
          -- triggered
          div_
            [ hxGet_ "/status"
            , hxTrigger_ "sse:status_update"
            ] do
            "GHC is building HelloWorld... Please wait."
          -- show received event data
          -- div_
          --   [ sseSwap_ "status_update"
          --   ] do
          --   "Received event data"

-- | Full page: send HTML headers
full :: UIState -> Html () -> Html ()
full state p = doctypehtml_ $ do
  head_ do
    title_ "GHC Profiler"
    script_ [ src_ "https://unpkg.com/htmx.org@1.9.5" ] emptyHtml
    script_ [ src_ "https://unpkg.com/htmx.org/dist/ext/sse.js" ] emptyHtml
    -- CSS style
    link_ [ href_ "/style.css", rel_ "stylesheet", type_ "text/css"]
  body_
    -- body listens to SSE events, hence inner elements can use hxTrigger
    -- "sse:event_name" to be triggered by an event and fetch an updated
    -- information (hxGet/hxPost...) or be replaced by the event data directly
    -- (sseSwap).
    [ hxExt_ "sse"
    , sseConnect_ "/events"
    ] do
      div_ [id_ "container"] do
        div_ [id_ "header"] do
          div_ [class_ "logo"] do
            "GHC profiler"
        div_ [id_ "sidenav"] do
          navHtml False state [0]
        div_ [id_ "main" ] do
          p

emptyHtml :: Monad m => HtmlT m ()
emptyHtml = mempty

helloHtml :: Html ()
helloHtml = do
  p_ "Hello World!"

  button_
    [ hxPost_ "/clicked"
    , hxSwap_ "outerHTML"
    ] do
    "Build HelloWorld with GHC"




data Nav = Nav
  { navTitle    :: Text               -- ^ Menu title
  , navContents :: UIState -> Html () -- ^ Page to show
  , navSubs     :: [Nav]              -- ^ Sub menu entries
  }

navs :: [Nav]
navs =
  [ Nav "Welcome" welcomeHtml []
  , Nav "Hello World" (const helloHtml)
      [ Nav "Sub item 1" (const "sub1") []
      , Nav "Sub item 2" (const "sub2") []
      , Nav "Sub item 3" (const "sub3") []
      ]
  ]

-- | Display the menu
navHtml :: Bool -> UIState -> [Int] -> Html ()
navHtml oob state path = do
  let (sel1,sel2,main_html) = case path of
        []    -> (Nothing,Nothing, const emptyHtml)
        [a]   -> (Just a, Nothing, navContents (navs !! a))
        a:b:_ -> (Just a, Just b,  navContents (navSubs (navs !! a) !! b))

  -- out-of-band swap of main contents
  when oob do
    div_
      [ id_ "main"
      , hxSwapOob_ "true"
      ] (main_html state)

  -- display the whole menu with style for selected elements
  div_
    [ id_ "sidemenu"
    ] do
    forM_ (navs `zip` [0..]) \(nav,i) -> do
      let is_selected1 = sel1 == Just i
      div_
        [ hxTarget_ "#sidenav"
        , hxGet_    ("/nav/" <> pack (show i))
        , class_    "navitem"
        , if is_selected1 then class_ "selected" else mempty
        ] $ toHtml (navTitle nav)
      when is_selected1 $ do
        div_
          [ class_ "navsub"
          ] do
          forM_ (navSubs nav `zip` [0..]) \(snav,j) -> do
            let is_selected2 = sel2 == Just j
            div_
              [ hxTarget_ "#sidenav"
              , hxGet_    ("nav/"<> pack (show i) <> "/" <> pack (show j))
              , class_    "navsubitem"
              , if is_selected2 then class_ "selected" else mempty
              ] $ toHtml (navTitle snav)
              -- We don't support third level nesting (yet)
