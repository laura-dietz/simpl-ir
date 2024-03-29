{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module SimplIR.HTML.Clean (clean, HtmlDocument(..)) where

import Data.Maybe (fromMaybe)
import Control.Applicative
import Data.List (mapAccumL)

import Control.DeepSeq
import qualified Data.HashSet as HS
import qualified Data.Text.Lazy as TL
import qualified Data.Text as T
import Data.Text (Text)
import Text.HTML.Parser

isTagOpenName :: TagName -> Token -> Bool
isTagOpenName name (TagOpen name' _) = name == name'
isTagOpenName _    _                 = False

isTagCloseName :: TagName -> Token -> Bool
isTagCloseName name (TagClose name') = name == name'
isTagCloseName _    _                = False

canonicalizeTags :: [Token] -> [Token]
canonicalizeTags = map f
  where
    f (TagOpen name attrs) = TagOpen (T.toLower name) attrs
    f (TagClose name)      = TagClose (T.toLower name)
    f other                = other

-- | Take the children of the first occurrence of the given tag.
insideTag :: Text -> [Token] -> [Token]
insideTag name =
      takeWhile (not . isTagCloseName name)
    . dropWhile (not . isTagOpenName name)

dropTags :: HS.HashSet Text -> [Token] -> [Token]
dropTags names = filterAccumL f Nothing
  where
    f Nothing (TagOpen name _)
      | name `HS.member` names  = (Just name, False)
      | otherwise               = (Nothing,   True)
    f (Just open) (TagClose name)
      | open == name            = (Nothing,   False)
    f open@(Just _) _           = (open,      False)
    f open  _                   = (open,      True)
{-# INLINE dropTags #-}

filterAccumL :: (acc -> a -> (acc, Bool)) -> acc -> [a] -> [a]
filterAccumL f z =
      map fst
    . filter snd
    . snd
    . mapAccumL (\acc x -> case f acc x of (acc', take) -> (acc', (x, take))) z
{-# INLINE filterAccumL #-}

extractTitle :: [Token] -> TL.Text
extractTitle =
    innerText' . insideTag "title" . takeWhile (not . isTagCloseName "head")

-- | Take the inner text of the first occurrence of the given tag
tagInnerText :: Text -> [Token] -> Maybe TL.Text
tagInnerText name tags =
    case insideTag name tags of
        []       -> Nothing
        children -> Just $ innerText' children

extractBody :: [Token] -> TL.Text
extractBody tags =
    let tags' = dropTags droppedTags tags
        droppedTags = HS.fromList [ "style" , "nav" , "video"
                                  , "canvas" , "script" ]
    in fromMaybe ""
       $  tagInnerText "article" tags'
      <|> tagInnerText "main" tags'
      <|> tagInnerText "body" tags'

innerText' :: [Token] -> TL.Text
innerText' = TL.fromChunks . map takeText
  where
    takeText (ContentChar t)            = T.singleton t
    takeText (ContentText t)            = t
    takeText (TagClose tag)
      | tag `HS.member` needsWhitespace = " "
    takeText (TagOpen tag _)
      | tag `HS.member` needsWhitespace = " "
    takeText _                          = ""

-- | Elements whose opening and closing tags should be mapped to whitespace in
-- inner-text.
needsWhitespace :: HS.HashSet Text
needsWhitespace = HS.fromList
    [ -- Block-level elements
      "address"
    , "article"
    , "aside"
    , "blockquote"
    , "canvas"
    , "dd"
    , "div"
    , "dl"
    , "fieldset"
    , "figcaption"
    , "figure"
    , "footer"
    , "form"
    , "h1", "h2", "h3", "h4", "h5", "h6"
    , "header"
    , "hgroup"
    , "hr"
    , "li"
    , "main"
    , "nav"
    , "noscript"
    , "ol"
    , "output"
    , "p"
    , "pre"
    , "section"
    , "table"
    , "tfoot"
    , "ul"
    , "video"

      -- others
    , "tr", "td", "th"
    , "br"
    ]

-- | Extract the essence of an HTML document.
clean :: Text -> HtmlDocument
clean content =
    let tags = canonicalizeTags
             $ parseTokens content
        docTitle = extractTitle tags
        docBody = extractBody tags
    in HtmlDocument {..}

data HtmlDocument = HtmlDocument { docTitle :: !TL.Text
                                 , docBody  :: !TL.Text
                                 }
                  deriving (Show)

instance NFData HtmlDocument where
    rnf (HtmlDocument {..}) =
        TL.length docTitle `seq` TL.length docBody `seq` ()
