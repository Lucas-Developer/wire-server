{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module API.Team (tests) where

import Bilge hiding (accept, timeout, head)
import Bilge.Assert
import Brig.Types hiding (Invitation (..), InvitationRequest (..), InvitationList (..))
import Brig.Types.Team.Invitation
import Brig.Types.User.Auth
import Brig.Types.Intra
import Control.Arrow ((&&&))
import Control.Lens ((^.), (^?), view)
import Control.Monad
import Control.Monad.IO.Class
import Data.Aeson
import Data.Aeson.Lens
import Data.ByteString.Conversion
import Data.ByteString.Lazy.Internal (ByteString)
import Data.Id hiding (client)
import Data.Maybe
import Data.Monoid ((<>))
import Data.Range
import Data.Text (Text)
import Network.HTTP.Client             (Manager)
import Test.Tasty hiding (Timeout)
import Test.Tasty.HUnit
import Web.Cookie (parseSetCookie, setCookieName)
import Util

import qualified Data.Text.Ascii             as Ascii
import qualified Data.Text.Encoding          as T
import qualified Data.UUID.V4                as UUID
import qualified Network.Wai.Utilities.Error as Error
import qualified Galley.Types.Teams          as Team

tests :: Manager -> Brig -> Galley -> IO TestTree
tests m b g =
    return $ testGroup "team"
        [ testGroup "invitation"
            [ test m "post /teams/:tid/invitations - 201"                $ testInvitationEmail b g
            , test m "post /teams/:tid/invitations - 403 no permission"  $ testInvitationNoPermission b
            , test m "post /register - 201 accepted"                     $ testInvitationEmailAccepted b g
            , test m "post /register user & team - 201 accepted"         $ testCreateTeam b g
            , test m "post /register - 400 no passwordless"              $ testTeamNoPassword b
            , test m "post /register - 400 code already used"            $ testInvitationCodeExists b g
            , test m "post /register - 400 bad code"                     $ testInvitationInvalidCode b
            , test m "post /register - 400 no wireless"                  $ testInvitationCodeNoIdentity b
            , test m "post /register - 400 mutually exclusive"           $ testInvitationMutuallyExclusive b
            , test m "get /teams/:tid/invitations - 200 (paging)"        $ testInvitationPaging b g
            , test m "get /teams/:tid/invitations/info - 200"            $ testInvitationInfo b g
            , test m "get /teams/:tid/invitations/info - 400"            $ testInvitationInfoBadCode b
            , test m "post /i/teams/:tid/suspend - 200"                  $ testSuspendTeam b g
            , test m "delete /self - 200 (ensure no orphan teams)"       $ testDeleteTeamUser b g
            ]
        ]

-------------------------------------------------------------------------------
-- Invitation Tests

testInvitationEmail :: Brig -> Galley -> Http ()
testInvitationEmail brig galley = do
    invitee <- randomEmail
    inviter <- userId <$> randomUser brig
    tid     <- createTeam inviter galley
    let invite = InvitationRequest invitee (Name "Bob") Nothing
    void $ postInvitation brig tid inviter invite

testInvitationEmailAccepted :: Brig -> Galley -> Http ()
testInvitationEmailAccepted brig galley = do
    inviteeEmail <- randomEmail
    inviter <- userId <$> randomUser brig
    tid     <- createTeam inviter galley
    let invite = InvitationRequest inviteeEmail (Name "Bob") Nothing
    Just inv <- decodeBody <$> postInvitation brig tid inviter invite
    Just inviteeCode <- getInvitationCode brig tid (inInvitation inv)
    rsp2 <- post (brig . path "/register"
                       . contentJson 
                       . body (accept inviteeEmail inviteeCode))
                  <!! const 201 === statusCode
    let Just (invitee, Just email2) = (userId &&& userEmail) <$> decodeBody rsp2
    let zuid = parseSetCookie <$> getHeader "Set-Cookie" rsp2
    liftIO $ assertEqual "Wrong cookie" (Just "zuid") (setCookieName <$> zuid)
    -- Verify that the invited user is active
    login brig (defEmailLogin email2) PersistentCookie !!! const 200 === statusCode
    -- Verify that the user is part of the team
    mem <- getTeamMember invitee tid galley
    liftIO $ assertBool "Member not part of the team" (invitee == mem ^. Team.userId)
    conns <- listConnections invitee brig
    liftIO $ assertBool "User should have no connections" (null (clConnections conns) && not (clHasMore conns))

testCreateTeam :: Brig -> Galley -> Http ()
testCreateTeam brig galley = do
    email <- randomEmail
    rsp <- register email newTeam brig
    let Just uid = userId <$> decodeBody rsp
    -- Verify that the user is part of exactly one (binding) team
    teams <- view Team.teamListTeams <$> getTeams uid galley
    liftIO $ assertBool "User not part of exactly one team" (length teams == 1)
    let team = fromMaybe (error "No team??") $ listToMaybe teams
    liftIO $ assertBool "Team not binding" (team^.Team.teamBinding == Team.Binding)
    mem <- getTeamMember uid (team^.Team.teamId) galley
    liftIO $ assertBool "Member not part of the team" (uid == mem ^. Team.userId)
    -- Verify that the user cannot send invitations before activating their account
    inviteeEmail <- randomEmail
    let invite = InvitationRequest inviteeEmail (Name "Bob") Nothing
    postInvitation brig (team^.Team.teamId) uid invite !!! const 403 === statusCode

testInvitationNoPermission :: Brig -> Http ()
testInvitationNoPermission brig = do
    alice <- userId <$> randomUser brig
    tid   <- randomTeamId
    email <- randomEmail
    let invite = InvitationRequest email (Name "Bob") Nothing
    postInvitation brig tid alice invite !!! do
        const 403 === statusCode
        const (Just "insufficient-permissions") === fmap Error.label . decodeBody

testTeamNoPassword :: Brig -> Http ()
testTeamNoPassword brig = do
    e <- randomEmail
    -- Team creators must have a password
    post (brig . path "/register" . contentJson . body (
        RequestBodyLBS . encode  $ object
            [ "name"  .= ("Bob" :: Text)
            , "email" .= fromEmail e
            , "team"  .= newTeam
            ]
        )) !!! const 400 === statusCode
    -- And so do any other binding team members
    code <- liftIO $ InvitationCode . Ascii.encodeBase64Url <$> randomBytes 24
    post (brig . path "/register" . contentJson . body (
        RequestBodyLBS . encode  $ object
            [ "name"      .= ("Bob" :: Text)
            , "email"     .= fromEmail e
            , "team_code" .= code
            ]
        )) !!! const 400 === statusCode

testInvitationCodeExists :: Brig -> Galley -> Http ()
testInvitationCodeExists brig galley = do
    email <- randomEmail
    uid   <- userId <$> randomUser brig
    tid   <- createTeam uid galley
    rsp   <- postInvitation brig tid uid (invite email) <!! const 201 === statusCode

    let Just invId = inInvitation <$> decodeBody rsp
    Just invCode <- getInvitationCode brig tid invId

    post (brig . path "/register" . contentJson . body (accept email invCode)) !!!
        const 201 === statusCode

    post (brig . path "/register" . contentJson . body (accept email invCode)) !!! do
        const 409                 === statusCode
        const (Just "key-exists") === fmap Error.label . decodeBody

    email2 <- randomEmail
    post (brig . path "/register" . contentJson . body (accept email2 invCode)) !!! do
        const 400 === statusCode
        const (Just "invalid-invitation-code") === fmap Error.label . decodeBody
 where
    invite email = InvitationRequest email (Name "Bob") Nothing

testInvitationInvalidCode :: Brig -> Http ()
testInvitationInvalidCode brig = do
    email <- randomEmail
    -- Syntactically invalid
    let code1 = InvitationCode (Ascii.unsafeFromText "8z6JVcO1o4o¿9kFeb4Y3N-BmhIjH6b33")
    post (brig . path "/register" . contentJson . body (accept email code1)) !!! do
        const 400 === statusCode
        const (Just "bad-request") === fmap Error.label . decodeBody
    -- Syntactically valid but semantically invalid
    code2 <- liftIO $ InvitationCode . Ascii.encodeBase64Url <$> randomBytes 24
    post (brig . path "/register" . contentJson . body (accept email code2)) !!! do
        const 400 === statusCode
        const (Just "invalid-invitation-code") === fmap Error.label . decodeBody

testInvitationCodeNoIdentity :: Brig -> Http ()
testInvitationCodeNoIdentity brig = do
    uid <- liftIO $ Id <$> UUID.nextRandom
    post (brig . path "/register" . contentJson . body (payload uid)) !!! do
        const 403                       === statusCode
        const (Just "missing-identity") === fmap Error.label . decodeBody
  where
    payload u = RequestBodyLBS . encode $ object
        [ "name"      .= ("Bob" :: Text)
        , "team_code" .= u
        , "password"  .= defPassword
        ]

testInvitationMutuallyExclusive :: Brig -> Http ()
testInvitationMutuallyExclusive brig = do
    email <- randomEmail
    code <- liftIO $ InvitationCode . Ascii.encodeBase64Url <$> randomBytes 24
    req email (Just code) (Just newTeam) Nothing      !!! const 400 === statusCode
    req email (Just code) Nothing        (Just code)  !!! const 400 === statusCode
    req email Nothing     (Just newTeam) (Just code)  !!! const 400 === statusCode
    req email (Just code) (Just newTeam) (Just code)  !!! const 400 === statusCode
  where
    req :: Email -> Maybe InvitationCode -> Maybe Team.BindingNewTeam -> Maybe InvitationCode
        -> HttpT IO (Response (Maybe ByteString))
    req e c t i = post (brig . path "/register" . contentJson . body (
        RequestBodyLBS . encode  $ object
            [ "name"            .= ("Bob" :: Text)
            , "email"           .= fromEmail e
            , "password"        .= defPassword
            , "team_code"       .= c
            , "team"            .= t
            , "invitation_code" .= i
            ]
        ))

testInvitationPaging :: Brig -> Galley -> Http ()
testInvitationPaging b g = do
    u     <- userId <$> randomUser b
    tid   <- createTeam u g
    replicateM_ total $ do
        email <- randomEmail
        postInvitation b tid u (invite email) !!! const 201 === statusCode
    foldM_ (next u tid 2) (0, Nothing) [2,2,1,0]
    foldM_ (next u tid total) (0, Nothing) [total,0]
  where
    total = 5

    next :: UserId -> TeamId -> Int -> (Int, Maybe InvitationId) -> Int -> Http (Int, Maybe InvitationId)
    next u t step (count, start) n = do
        let count' = count + step
        let range = queryRange (toByteString' <$> start) (Just step)
        r <- get (b . paths ["teams", toByteString' t, "invitations"] . zUser u . range) <!!
            const 200 === statusCode
        let (invs, more) = (fmap ilInvitations &&& fmap ilHasMore) $ decodeBody r
        liftIO $ assertEqual "page size" (Just n) (length <$> invs)
        liftIO $ assertEqual "has more" (Just (count' < total)) more
        return . (count',) $ invs >>= fmap inInvitation . listToMaybe . reverse

    invite email = InvitationRequest email (Name "Bob") Nothing

testInvitationInfo :: Brig -> Galley -> Http ()
testInvitationInfo brig galley = do
    email    <- randomEmail
    uid      <- userId <$> randomUser brig
    tid      <- createTeam uid galley
    let invite = InvitationRequest email (Name "Bob") Nothing
    Just inv <- decodeBody <$> postInvitation brig tid uid invite

    Just invCode    <- getInvitationCode brig tid (inInvitation inv)
    Just invitation <- getInvitation brig invCode

    liftIO $ assertEqual "Invitations differ" inv invitation

testInvitationInfoBadCode :: Brig -> Http ()
testInvitationInfoBadCode brig = do
    -- The code contains non-ASCII characters after url-decoding
    let icode = "8z6JVcO1o4o%C2%BF9kFeb4Y3N-BmhIjH6b33"
    get (brig . path ("/teams/invitations/info?code=" <> icode)) !!!
        const 400 === statusCode

testSuspendTeam :: Brig -> Galley -> Http ()
testSuspendTeam brig galley = do
    inviteeEmail  <- randomEmail
    inviteeEmail2 <- randomEmail
    inviter       <- userId <$> randomUser brig
    tid           <- createTeam inviter galley

    -- invite and register invitee
    let invite  = InvitationRequest inviteeEmail (Name "Bob") Nothing
    Just inv <- decodeBody <$> postInvitation brig tid inviter invite
    Just inviteeCode <- getInvitationCode brig tid (inInvitation inv)
    rsp2 <- post (brig . path "/register"
                       . contentJson
                       . body (accept inviteeEmail inviteeCode))
                  <!! const 201 === statusCode
    let Just (invitee, Just email) = (userId &&& userEmail) <$> decodeBody rsp2

    -- invite invitee2 (don't register)
    let invite2 = InvitationRequest inviteeEmail2 (Name "Bob") Nothing
    Just inv2 <- decodeBody <$> postInvitation brig tid inviter invite2
    Just _ <- getInvitationCode brig tid (inInvitation inv2)

    -- suspend team
    suspendTeam brig tid !!! const 200 === statusCode
    -- login fails
    login brig (defEmailLogin email) PersistentCookie !!! do
       const 403 === statusCode
       const (Just "suspended") === fmap Error.label . decodeBody
    -- check status
    chkStatus brig inviter Suspended
    chkStatus brig invitee Suspended
    assertNoInvitationCode brig tid (inInvitation inv2)

    -- unsuspend
    unsuspendTeam brig tid !!! const 200 === statusCode
    chkStatus brig inviter Active
    chkStatus brig invitee Active
    login brig (defEmailLogin email) PersistentCookie !!! const 200 === statusCode

testDeleteTeamUser :: Brig -> Galley -> Http ()
testDeleteTeamUser brig galley = do
    creator <- userId <$> randomUser brig
    tid     <- createTeam creator galley
    -- Cannot delete the user since it will make the team orphan
    deleteUser creator (Just defPassword) brig !!! do
        const 403 === statusCode
        const (Just "no-other-full-permission-member") === fmap Error.label . decodeBody
    -- We need to invite another user to a full permission member
    invitee <- inviteAndRegisterUser creator tid brig
    -- Still cannot delete, need to make this a full permission member
    deleteUser creator (Just defPassword) brig !!! do
        const 403 === statusCode
        const (Just "no-other-full-permission-member") === fmap Error.label . decodeBody
    -- Let's promote the other user
    updatePermissions creator tid (invitee, Team.fullPermissions) galley
    -- Now the creator can delete the account
    deleteUser creator (Just defPassword) brig !!! const 200 === statusCode
    -- The new owner cannot
    deleteUser invitee (Just defPassword) brig !!! const 403 === statusCode
    -- We can still invite new users who can delete their account, regardless of status
    inviteeFull <- inviteAndRegisterUser invitee tid brig
    updatePermissions invitee tid (inviteeFull, Team.fullPermissions) galley
    deleteUser inviteeFull (Just defPassword) brig !!! const 200 === statusCode

    inviteeMember <- inviteAndRegisterUser invitee tid brig
    deleteUser inviteeMember (Just defPassword) brig !!! const 200 === statusCode

    deleteUser invitee (Just defPassword) brig !!! do
        const 403 === statusCode
        const (Just "no-other-full-permission-member") === fmap Error.label . decodeBody

-------------------------------------------------------------------------------
-- Utilities

listConnections :: UserId -> Brig -> Http UserConnectionList
listConnections u brig = do
    r <- get $ brig
             . path "connections"
             . zUser u
    return $ fromMaybe (error "listConnections: failed to parse response") (decodeBody r)

getInvitation :: Brig -> InvitationCode -> Http (Maybe Invitation)
getInvitation brig c = do
    r <- get $ brig
             . path "/teams/invitations/info"
             . queryItem "code" (toByteString' c)
    return . decode . fromMaybe "" $ responseBody r

postInvitation :: Brig -> TeamId -> UserId -> InvitationRequest -> Http ResponseLBS
postInvitation brig t u i = post $ brig
    . paths ["teams", toByteString' t, "invitations"]
    . contentJson
    . body (RequestBodyLBS $ encode i)
    . zAuthAccess u "conn"

suspendTeam :: Brig -> TeamId -> HttpT IO (Response (Maybe ByteString))
suspendTeam brig t = post $ brig
    . paths ["i", "teams", toByteString' t, "suspend"]
    . contentJson

unsuspendTeam :: Brig -> TeamId -> Http ResponseLBS
unsuspendTeam brig t = post $ brig
    . paths ["i", "teams", toByteString' t, "unsuspend"]
    . contentJson

getInvitationCode :: Brig -> TeamId -> InvitationId -> Http (Maybe InvitationCode)
getInvitationCode brig t ref = do
    r <- get ( brig
             . path "/i/teams/invitation-code"
             . queryItem "team" (toByteString' t)
             . queryItem "invitation_id" (toByteString' ref)
             )
    let lbs   = fromMaybe "" $ responseBody r
    return $ fromByteString . fromMaybe (error "No code?") $ T.encodeUtf8 <$> (lbs ^? key "code"  . _String)

assertNoInvitationCode :: Brig -> TeamId -> InvitationId -> Http ()
assertNoInvitationCode brig t i =
    get ( brig
        . path "/i/teams/invitation-code"
        . queryItem "team" (toByteString' t)
        . queryItem "invitation_id" (toByteString' i)
        ) !!! do
          const 400 === statusCode
          const (Just "invalid-invitation-code") === fmap Error.label . decodeBody

randomTeamId :: MonadIO m => m TeamId
randomTeamId = Id <$> liftIO UUID.nextRandom

createTeam :: UserId -> Galley -> Http TeamId
createTeam u galley = do
    tid <- randomId
    r <- put ( galley
              . paths ["i", "teams", toByteString' tid]
              . contentJson
              . zAuthAccess u "conn"
              . expect2xx
              . lbytes (encode newTeam)
              )
    maybe (error "invalid team id") return $
        fromByteString $ getHeader' "Location" r

getTeamMember :: UserId -> TeamId -> Galley -> Http Team.TeamMember
getTeamMember u tid galley = do
    r <- get ( galley
             . paths ["i", "teams", toByteString' tid, "members", toByteString' u]
             . zUser u
             . expect2xx
             )
    return $ fromMaybe (error "getTeamMember: failed to parse response") (decodeBody r)

getTeams :: UserId -> Galley -> Http Team.TeamList
getTeams u galley = do
    r <- get ( galley
             . paths ["teams"]
             . zAuthAccess u "conn"
             . expect2xx
             )
    return $ fromMaybe (error "getTeams: failed to parse response") (decodeBody r)

accept :: Email -> InvitationCode -> RequestBody
accept email code = RequestBodyLBS . encode $ object
    [ "name"      .= ("Bob" :: Text)
    , "email"     .= fromEmail email
    , "password"  .= defPassword
    , "team_code" .= code
    ]

register :: Email -> Team.BindingNewTeam -> Brig -> HttpT IO (Response (Maybe ByteString))
register e t brig = post (brig . path "/register" . contentJson . body (
    RequestBodyLBS . encode  $ object
        [ "name"            .= ("Bob" :: Text)
        , "email"           .= fromEmail e
        , "password"        .= defPassword
        , "team"            .= t
        ]
    ))

inviteAndRegisterUser :: UserId -> TeamId -> Brig -> HttpT IO UserId
inviteAndRegisterUser u tid brig = do
    inviteeEmail <- randomEmail
    let invite = InvitationRequest inviteeEmail (Name "Bob") Nothing
    Just inv <- decodeBody <$> postInvitation brig tid u invite
    Just inviteeCode <- getInvitationCode brig tid (inInvitation inv)
    rspInvitee <- post (brig . path "/register"
                             . contentJson
                             . body (accept inviteeEmail inviteeCode)) <!! const 201 === statusCode

    let Just invitee = userId <$> decodeBody rspInvitee
    return invitee

updatePermissions :: UserId -> TeamId -> (UserId, Team.Permissions) -> Galley -> HttpT IO ()
updatePermissions from tid (to, perm) galley =
    put ( galley
        . paths ["teams", toByteString' tid, "members"]
        . zUser from
        . zConn "conn"
        . Bilge.json changeMember
        ) !!! const 200 === statusCode
  where
    changeMember = Team.newNewTeamMember $ Team.newTeamMember to perm

newTeam :: Team.BindingNewTeam
newTeam = Team.BindingNewTeam $ Team.newNewTeam (unsafeRange "teamName") (unsafeRange "defaultIcon")
