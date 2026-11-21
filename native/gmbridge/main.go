// gmbridge: Google 메시지(libgm) 클라이언트를 Flutter(dart:ffi)에서 쓰기 위한 C 공유 라이브러리.
//
// 통신 규약
//   - GmStart(dataDir, callback): 초기화. 이후 모든 이벤트·응답은 callback(json) 으로 전달된다.
//   - GmRequest(json): {"id":n,"method":"...","args":{...}} 비동기 요청. 결과는
//     {"type":"result","id":n,"ok":true,"data":...} 이벤트로 돌아온다.
//   - GmFree(ptr): callback 으로 받은 문자열 해제 (Dart 쪽에서 읽은 뒤 호출).
package main

/*
#include <stdlib.h>
typedef void (*gm_event_cb)(char*);
static inline void gm_call_cb(gm_event_cb cb, char* s) { if (cb) cb(s); }
*/
import "C"

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/rs/zerolog"
	"go.mau.fi/util/exhttp"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

type bridge struct {
	mu       sync.Mutex
	cb       C.gm_event_cb
	dataDir  string
	log      zerolog.Logger
	client   *libgm.Client
	authData *libgm.AuthData

	convs map[string]*gmproto.Conversation
	sims  map[string]*gmproto.SIMCard // participantID -> SIM

	pairCancel context.CancelFunc
	ctx        context.Context
	cancel     context.CancelFunc
}

var b = &bridge{
	convs: map[string]*gmproto.Conversation{},
	sims:  map[string]*gmproto.SIMCard{},
}

func main() {}

// ───────────────────────── C 진입점 ─────────────────────────

//export GmStart
func GmStart(dataDir *C.char, cb C.gm_event_cb) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.cb = cb
	b.dataDir = C.GoString(dataDir)
	_ = os.MkdirAll(b.dataDir, 0o700)
	logFile, err := os.OpenFile(filepath.Join(b.dataDir, "gmbridge.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err == nil {
		b.log = zerolog.New(logFile).With().Timestamp().Logger().Level(zerolog.InfoLevel)
	} else {
		b.log = zerolog.Nop()
	}
	b.ctx, b.cancel = context.WithCancel(context.Background())
}

//export GmRequest
func GmRequest(req *C.char) {
	raw := C.GoString(req)
	go handleRequest(raw)
}

//export GmFree
func GmFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

// ───────────────────────── 이벤트 전송 ─────────────────────────

func emit(v map[string]any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	cs := C.CString(string(data))
	C.gm_call_cb(b.cb, cs) // 해제는 Dart 쪽 GmFree
}

func emitStatus(state, msg string) {
	emit(map[string]any{"type": "status", "state": state, "message": msg})
}

type request struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Args   json.RawMessage `json:"args"`
}

func handleRequest(raw string) {
	var req request
	if err := json.Unmarshal([]byte(raw), &req); err != nil {
		return
	}
	defer func() {
		if r := recover(); r != nil {
			emit(map[string]any{"type": "result", "id": req.ID, "ok": false, "error": fmt.Sprint("panic: ", r)})
		}
	}()
	ctx, cancel := context.WithTimeout(b.ctx, 90*time.Second)
	defer cancel()
	data, err := dispatch(ctx, req.Method, req.Args)
	if err != nil {
		b.log.Warn().Err(err).Str("method", req.Method).Msg("request failed")
		emit(map[string]any{"type": "result", "id": req.ID, "ok": false, "error": err.Error()})
		return
	}
	emit(map[string]any{"type": "result", "id": req.ID, "ok": true, "data": data})
}

func args[T any](raw json.RawMessage) (T, error) {
	var v T
	if len(raw) == 0 {
		return v, nil
	}
	err := json.Unmarshal(raw, &v)
	return v, err
}

var errNotLoggedIn = errors.New("not logged in")

func (br *bridge) cli() (*libgm.Client, error) {
	br.mu.Lock()
	defer br.mu.Unlock()
	if br.client == nil {
		return nil, errNotLoggedIn
	}
	return br.client, nil
}

func dispatch(ctx context.Context, method string, raw json.RawMessage) (any, error) {
	switch method {
	case "init":
		return doInit()
	case "login":
		a, err := args[struct {
			Cookies map[string]string `json:"cookies"`
		}](raw)
		if err != nil {
			return nil, err
		}
		return doLogin(ctx, a.Cookies)
	case "cancelLogin":
		b.mu.Lock()
		if b.pairCancel != nil {
			b.pairCancel()
		}
		b.mu.Unlock()
		return nil, nil
	case "logout":
		return nil, doLogout(ctx)
	case "reconnect":
		return nil, doReconnect()
	case "conversations":
		a, _ := args[struct {
			Folder string `json:"folder"`
			Count  int64  `json:"count"`
		}](raw)
		return listConversations(ctx, a.Folder, a.Count)
	case "messages":
		a, err := args[struct {
			ConvID   string `json:"convId"`
			Count    int64  `json:"count"`
			CursorID string `json:"cursorId"`
			CursorTS int64  `json:"cursorTs"`
		}](raw)
		if err != nil {
			return nil, err
		}
		return fetchMessages(ctx, a.ConvID, a.Count, a.CursorID, a.CursorTS)
	case "send":
		a, err := args[sendArgs](raw)
		if err != nil {
			return nil, err
		}
		return sendMessage(ctx, a)
	case "markRead":
		a, err := args[struct {
			ConvID string `json:"convId"`
			MsgID  string `json:"msgId"`
		}](raw)
		if err != nil {
			return nil, err
		}
		c, err := b.cli()
		if err != nil {
			return nil, err
		}
		return nil, c.MarkRead(ctx, a.ConvID, a.MsgID)
	case "typing":
		a, err := args[struct {
			ConvID string `json:"convId"`
			Typing bool   `json:"typing"`
		}](raw)
		if err != nil {
			return nil, err
		}
		c, err := b.cli()
		if err != nil {
			return nil, err
		}
		return nil, c.SetTyping(ctx, a.ConvID, a.Typing, b.simPayloadFor(a.ConvID))
	case "react":
		a, err := args[struct {
			ConvID string `json:"convId"`
			MsgID  string `json:"msgId"`
			Emoji  string `json:"emoji"`
			Remove bool   `json:"remove"`
		}](raw)
		if err != nil {
			return nil, err
		}
		c, err := b.cli()
		if err != nil {
			return nil, err
		}
		action := gmproto.SendReactionRequest_ADD
		if a.Remove {
			action = gmproto.SendReactionRequest_REMOVE
		}
		_, err = c.SendReaction(ctx, &gmproto.SendReactionRequest{
			MessageID:    a.MsgID,
			ReactionData: &gmproto.ReactionData{Unicode: a.Emoji, Type: emojiType(a.Emoji)},
			Action:       action,
			SIMPayload:   b.simPayloadFor(a.ConvID),
		})
		return nil, err
	case "deleteMessage":
		a, err := args[struct {
			MsgID string `json:"msgId"`
		}](raw)
		if err != nil {
			return nil, err
		}
		c, err := b.cli()
		if err != nil {
			return nil, err
		}
		resp, err := c.DeleteMessage(ctx, a.MsgID)
		if err != nil {
			return nil, err
		}
		return map[string]any{"success": resp.GetSuccess()}, nil
	case "thumbnails":
		a, err := args[struct {
			IDs []string `json:"ids"`
		}](raw)
		if err != nil {
			return nil, err
		}
		return thumbnails(ctx, a.IDs)
	case "fullImage":
		// 미리보기만 온 사진의 원본을 휴대폰에 요청한다 (올라오면 메시지 갱신 이벤트로 온다)
		a, err := args[struct {
			MsgID  string `json:"msgId"`
			PartID string `json:"partId"`
		}](raw)
		if err != nil {
			return nil, err
		}
		c, err := b.cli()
		if err != nil {
			return nil, err
		}
		if _, err := c.GetFullSizeImage(ctx, a.MsgID, a.PartID); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	case "download":
		a, err := args[struct {
			MediaID string `json:"mediaId"`
			Key     string `json:"key"`
			Path    string `json:"path"`
		}](raw)
		if err != nil {
			return nil, err
		}
		return download(ctx, a.MediaID, a.Key, a.Path)
	case "contacts":
		c, err := b.cli()
		if err != nil {
			return nil, err
		}
		resp, err := c.ListContacts(ctx)
		if err != nil {
			return nil, err
		}
		out := make([]map[string]any, 0, len(resp.GetContacts()))
		for _, ct := range resp.GetContacts() {
			out = append(out, map[string]any{
				"id":     ct.GetContactID(),
				"name":   ct.GetName(),
				"number": ct.GetNumber().GetNumber(),
				"formatted": func() string {
					if f := ct.GetNumber().GetFormattedNumber(); f != "" {
						return f
					}
					return ct.GetNumber().GetNumber()
				}(),
				"color": ct.GetAvatarHexColor(),
			})
		}
		return out, nil
	case "startConversation":
		a, err := args[struct {
			Numbers   []string `json:"numbers"`
			GroupName string   `json:"groupName"`
		}](raw)
		if err != nil {
			return nil, err
		}
		c, err := b.cli()
		if err != nil {
			return nil, err
		}
		nums := make([]*gmproto.ContactNumber, 0, len(a.Numbers))
		for _, n := range a.Numbers {
			nums = append(nums, &gmproto.ContactNumber{MysteriousInt: 7, Number: n, Number2: n})
		}
		req := &gmproto.GetOrCreateConversationRequest{Numbers: nums}
		resp, err := c.GetOrCreateConversation(ctx, req)
		if err != nil {
			return nil, err
		}
		// 모두 RCS 를 쓰는 그룹이면 휴대폰이 "RCS 그룹으로 만들라"고 답한다 (웹과 같은 흐름)
		if resp.GetConversation() == nil && resp.GetStatus() == gmproto.GetOrCreateConversationResponse_CREATE_RCS {
			create := true
			req.CreateRCSGroup = &create
			if name := strings.TrimSpace(a.GroupName); name != "" {
				req.RCSGroupName = &name
			}
			resp, err = c.GetOrCreateConversation(ctx, req)
			if err != nil {
				return nil, err
			}
		}
		if resp.GetConversation() == nil {
			return nil, fmt.Errorf("대화를 만들지 못했습니다 (status %s)", resp.GetStatus())
		}
		b.storeConv(resp.GetConversation())
		return convJSON(resp.GetConversation()), nil
	case "updateConversation":
		a, err := args[struct {
			ConvID string `json:"convId"`
			// archive | unarchive | delete | block | spam | unblock | mute | unmute | rename
			Action string `json:"action"`
			Name   string `json:"name"`
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, updateConversation(ctx, a.ConvID, a.Action, a.Name)
	case "setActive":
		// 다른 곳(브라우저 등)에서 메시지 웹을 열어 이 앱이 비활성화됐을 때 "여기서 사용"
		c, err := b.cli()
		if err != nil {
			return nil, err
		}
		return nil, c.SetActiveSession(ctx)
	}
	return nil, fmt.Errorf("unknown method %q", method)
}

// ───────────────────────── 세션 ─────────────────────────

func (br *bridge) sessionPath() string { return filepath.Join(br.dataDir, "session.json") }

func (br *bridge) saveSession() {
	br.mu.Lock()
	ad := br.authData
	br.mu.Unlock()
	if ad == nil {
		return
	}
	data, err := json.Marshal(ad)
	if err != nil {
		br.log.Err(err).Msg("marshal session")
		return
	}
	tmp := br.sessionPath() + ".tmp"
	if err = os.WriteFile(tmp, data, 0o600); err == nil {
		err = os.Rename(tmp, br.sessionPath())
	}
	if err != nil {
		br.log.Err(err).Msg("save session")
	}
}

func (br *bridge) deleteSession() {
	_ = os.Remove(br.sessionPath())
}

func newClient(ad *libgm.AuthData) *libgm.Client {
	settings := exhttp.SensibleClientSettings
	c := libgm.NewClient(ad, nil, b.log.With().Str("component", "libgm").Logger(), settings)
	c.SetEventHandler(handleEvent)
	return c
}

func doInit() (any, error) {
	data, err := os.ReadFile(b.sessionPath())
	if err != nil {
		return map[string]any{"loggedIn": false}, nil
	}
	ad := libgm.NewAuthData()
	if err = json.Unmarshal(data, ad); err != nil {
		b.log.Err(err).Msg("invalid session file")
		return map[string]any{"loggedIn": false}, nil
	}
	if !ad.IsGoogleAccount() || ad.Mobile == nil {
		return map[string]any{"loggedIn": false}, nil
	}
	b.mu.Lock()
	b.authData = ad
	b.client = newClient(ad)
	b.mu.Unlock()
	go connect()
	return map[string]any{"loggedIn": true}, nil
}

func connect() {
	c, err := b.cli()
	if err != nil {
		return
	}
	emitStatus("connecting", "")
	if err = c.Connect(b.ctx); err != nil {
		b.log.Err(err).Msg("connect failed")
		msg := err.Error()
		if strings.Contains(msg, "401") || strings.Contains(msg, "403") || strings.Contains(strings.ToLower(msg), "unauth") {
			emitStatus("auth_error", msg)
		} else {
			emitStatus("error", msg)
		}
		return
	}
	emitStatus("connected", "")
	b.saveSession()
}

func doReconnect() error {
	c, err := b.cli()
	if err != nil {
		return err
	}
	emitStatus("connecting", "")
	go func() {
		if err := c.Reconnect(b.ctx); err != nil {
			emitStatus("error", err.Error())
			return
		}
		emitStatus("connected", "")
	}()
	return nil
}

func doLogin(ctx context.Context, cookies map[string]string) (any, error) {
	if len(cookies) == 0 || cookies["SAPISID"] == "" {
		return nil, errors.New("Google 로그인 쿠키(SAPISID)를 찾지 못했습니다. 다시 로그인해 주세요.")
	}
	ad := libgm.NewAuthData()
	ad.Cookies = cookies
	c := libgm.NewClient(ad, nil, b.log.With().Str("component", "libgm-pair").Logger(), exhttp.SensibleClientSettings)
	c.SetEventHandler(func(evt any) {
		b.log.Debug().Type("event_type", evt).Msg("pre-pair event")
	})
	if err := c.FetchConfig(ctx); err != nil {
		if strings.Contains(err.Error(), "401") || strings.Contains(err.Error(), "403") {
			return nil, errors.New("Google 로그인 정보가 메시지 서버에서 인증되지 않았습니다. '다른 계정으로 로그인'을 눌러 로그인 정보를 지운 뒤 다시 로그인해 주세요.")
		}
		return nil, fmt.Errorf("설정을 가져오지 못했습니다: %w", err)
	}
	bgCtx, cancel := context.WithCancel(b.ctx)
	b.mu.Lock()
	if b.pairCancel != nil {
		b.pairCancel()
	}
	b.pairCancel = cancel
	b.mu.Unlock()

	emoji, sess, err := c.StartGaiaPairing(ctx, bgCtx)
	if err != nil {
		cancel()
		c.Disconnect()
		return nil, pairStartError(err)
	}
	go func() {
		defer cancel()
		phoneID, err := c.FinishGaiaPairing(bgCtx, sess)
		if err != nil {
			c.Disconnect()
			emit(map[string]any{"type": "pair_error", "error": pairWaitError(err)})
			return
		}
		c.Disconnect()
		b.mu.Lock()
		b.authData = c.AuthData
		b.client = newClient(c.AuthData)
		b.mu.Unlock()
		b.saveSession()
		emit(map[string]any{"type": "paired", "phoneId": phoneID})
		connect()
	}()
	return map[string]any{"emoji": emoji, "svg": libgm.GetEmojiSVG(emoji)}, nil
}

func pairStartError(err error) error {
	switch {
	case errors.Is(err, libgm.ErrNoDevicesFound):
		return errors.New("이 Google 계정에 연결된 휴대폰을 찾지 못했습니다. 휴대폰 Google 메시지 앱에서 같은 계정으로 로그인되어 있는지 확인하세요.")
	case errors.Is(err, libgm.ErrPhoneNotFound):
		return errors.New("휴대폰을 찾지 못했습니다.")
	case errors.Is(err, libgm.ErrPhoneInactive):
		return errors.New("휴대폰이 응답하지 않습니다. 휴대폰에서 Google 메시지 앱을 한 번 열어 주세요.")
	case errors.Is(err, libgm.ErrPairingInitTimeout):
		return errors.New("휴대폰 응답 시간이 초과되었습니다. 휴대폰이 인터넷에 연결되어 있는지 확인하세요.")
	case errors.Is(err, events.ErrCallerNoPermission):
		return errors.New("이 계정으로는 페어링할 권한이 없습니다.")
	}
	return fmt.Errorf("페어링을 시작하지 못했습니다: %w", err)
}

func pairWaitError(err error) string {
	switch {
	case errors.Is(err, libgm.ErrIncorrectEmoji):
		return "다른 이모티콘을 선택했습니다. 다시 시도해 주세요."
	case errors.Is(err, libgm.ErrPairingCancelled):
		return "휴대폰에서 연결을 취소했습니다."
	case errors.Is(err, libgm.ErrPairingTimeout):
		return "시간이 초과되었습니다. 다시 시도해 주세요."
	case errors.Is(err, context.Canceled):
		return "취소되었습니다."
	}
	return "페어링 실패: " + err.Error()
}

func doLogout(ctx context.Context) error {
	b.mu.Lock()
	c := b.client
	b.client = nil
	b.authData = nil
	b.convs = map[string]*gmproto.Conversation{}
	b.mu.Unlock()
	if c != nil {
		_ = c.UnpairGaia(ctx)
		c.Disconnect()
	}
	b.deleteSession()
	return nil
}

// ───────────────────────── 이벤트 처리 ─────────────────────────

func handleEvent(rawEvt any) {
	switch evt := rawEvt.(type) {
	case *events.ListenFatalError:
		emitStatus("error", evt.Error.Error())
	case *events.ListenTemporaryError:
		emitStatus("reconnecting", evt.Error.Error())
	case *events.ListenRecovered:
		emitStatus("connected", "")
	case *events.PhoneNotResponding:
		emitStatus("phone_not_responding", "")
	case *events.PhoneRespondingAgain:
		emitStatus("connected", "")
	case *events.PingFailed:
		emitStatus("reconnecting", evt.Error.Error())
	case *gmproto.RevokePairData:
		loggedOut()
	case *events.GaiaLoggedOut:
		loggedOut()
	case *events.AuthTokenRefreshed:
		go b.saveSession()
	case *gmproto.Conversation:
		b.storeConv(evt)
		emit(map[string]any{"type": "conversation", "conv": convJSON(evt)})
	case *libgm.WrappedMessage:
		emit(map[string]any{"type": "message", "msg": msgJSON(evt.Message), "isOld": evt.IsOld})
	case *gmproto.TypingData:
		emit(map[string]any{
			"type":   "typing",
			"convId": evt.GetConversationID(),
			"number": evt.GetUser().GetNumber(),
			"typing": evt.GetType() == gmproto.TypingTypes_STARTED_TYPING,
		})
	case *gmproto.Settings:
		b.mu.Lock()
		for _, sim := range evt.GetSIMCards() {
			b.sims[sim.GetSIMParticipant().GetID()] = sim
		}
		b.mu.Unlock()
		sims := make([]map[string]any, 0)
		for _, sim := range evt.GetSIMCards() {
			sims = append(sims, map[string]any{
				"participantId": sim.GetSIMParticipant().GetID(),
				"carrier":       sim.GetSIMData().GetCarrierName(),
				"number":        sim.GetSIMData().GetFormattedPhoneNumber(),
				"color":         sim.GetSIMData().GetColorHex(),
				"slot":          sim.GetSIMData().GetSIMPayload().GetSIMNumber(),
				"rcs":           sim.GetRCSChats().GetEnabled(),
			})
		}
		rcs := evt.GetRCSSettings()
		emit(map[string]any{
			"type": "settings",
			"sims": sims,
			"rcs": map[string]any{
				"enabled":          rcs.GetIsEnabled(),
				"readReceipts":     rcs.GetSendReadReceipts(),
				"typingIndicators": rcs.GetShowTypingIndicators(),
			},
			"phoneAppVersion": evt.GetBugleVersion(),
		})
	case *gmproto.UserAlertEvent:
		// 휴대폰 상태 알림: 모바일 데이터 사용, 배터리 부족, 다른 곳에서 사용 중 등
		emit(map[string]any{"type": "alert", "alert": evt.GetAlertType().String()})
	case *events.PairSuccessful:
		go b.saveSession()
	}
}

func loggedOut() {
	b.mu.Lock()
	c := b.client
	b.client = nil
	b.authData = nil
	b.mu.Unlock()
	if c != nil {
		c.Disconnect()
	}
	b.deleteSession()
	emitStatus("logged_out", "")
}

func (br *bridge) storeConv(c *gmproto.Conversation) {
	br.mu.Lock()
	br.convs[c.GetConversationID()] = c
	br.mu.Unlock()
}

func (br *bridge) simPayloadFor(convID string) *gmproto.SIMPayload {
	br.mu.Lock()
	defer br.mu.Unlock()
	conv := br.convs[convID]
	if conv != nil {
		if sim, ok := br.sims[conv.GetDefaultOutgoingID()]; ok {
			return sim.GetSIMData().GetSIMPayload()
		}
		if p := conv.GetSimCard().GetSIMData().GetSIMPayload(); p != nil {
			return p
		}
	}
	for _, sim := range br.sims {
		return sim.GetSIMData().GetSIMPayload()
	}
	return nil
}

// ───────────────────────── 조회 ─────────────────────────

func listConversations(ctx context.Context, folder string, count int64) (any, error) {
	c, err := b.cli()
	if err != nil {
		return nil, err
	}
	if count <= 0 {
		count = 75
	}
	f := gmproto.ListConversationsRequest_INBOX
	switch folder {
	case "archive":
		f = gmproto.ListConversationsRequest_ARCHIVE
	case "spam":
		f = gmproto.ListConversationsRequest_SPAM_BLOCKED
	}
	resp, err := c.ListConversations(ctx, &gmproto.ListConversationsRequest{Count: count, Folder: f})
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(resp.GetConversations()))
	for _, conv := range resp.GetConversations() {
		b.storeConv(conv)
		out = append(out, convJSON(conv))
	}
	return out, nil
}

func fetchMessages(ctx context.Context, convID string, count int64, cursorID string, cursorTS int64) (any, error) {
	c, err := b.cli()
	if err != nil {
		return nil, err
	}
	if count <= 0 {
		count = 50
	}
	var cursor *gmproto.Cursor
	if cursorID != "" {
		cursor = &gmproto.Cursor{LastItemID: cursorID, LastItemTimestamp: cursorTS}
	}
	resp, err := c.FetchMessages(ctx, convID, count, cursor)
	if err != nil {
		return nil, err
	}
	msgs := make([]map[string]any, 0, len(resp.GetMessages()))
	for _, m := range resp.GetMessages() {
		msgs = append(msgs, msgJSON(m))
	}
	sort.SliceStable(msgs, func(i, j int) bool { return msgs[i]["ts"].(int64) < msgs[j]["ts"].(int64) })
	out := map[string]any{"messages": msgs}
	if cur := resp.GetCursor(); cur != nil && cur.GetLastItemID() != "" {
		out["cursorId"] = cur.GetLastItemID()
		out["cursorTs"] = cur.GetLastItemTimestamp()
	}
	return out, nil
}

func thumbnails(ctx context.Context, ids []string) (any, error) {
	c, err := b.cli()
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	if len(ids) == 0 {
		return out, nil
	}
	resp, err := c.GetParticipantThumbnail(ctx, ids...)
	if err != nil {
		return nil, err
	}
	for _, t := range resp.GetThumbnail() {
		if buf := t.GetData().GetImageBuffer(); len(buf) > 0 {
			out[t.GetIdentifier()] = base64.StdEncoding.EncodeToString(buf)
		}
	}
	return out, nil
}

func download(ctx context.Context, mediaID, key, path string) (any, error) {
	c, err := b.cli()
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(path); err == nil {
		return map[string]any{"path": path}, nil
	}
	k, err := base64.StdEncoding.DecodeString(key)
	if err != nil {
		return nil, err
	}
	rc, err := c.DownloadMedia(ctx, mediaID, k)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	_ = os.MkdirAll(filepath.Dir(path), 0o700)
	tmp := path + ".part"
	f, err := os.Create(tmp)
	if err != nil {
		return nil, err
	}
	_, err = io.Copy(f, rc)
	f.Close()
	if err != nil {
		os.Remove(tmp)
		return nil, err
	}
	if err = os.Rename(tmp, path); err != nil {
		return nil, err
	}
	return map[string]any{"path": path}, nil
}

// 대화 상대(내가 아닌 첫 참여자)의 전화번호. 삭제·차단 요청에 함께 보낸다.
func (br *bridge) peerPhone(convID string) string {
	br.mu.Lock()
	defer br.mu.Unlock()
	if conv := br.convs[convID]; conv != nil {
		for _, p := range conv.GetParticipants() {
			if !p.GetIsMe() && p.GetID().GetNumber() != "" {
				return p.GetID().GetNumber()
			}
		}
	}
	return ""
}

func updateConversation(ctx context.Context, convID, action, name string) error {
	c, err := b.cli()
	if err != nil {
		return err
	}
	switch action {
	case "delete":
		return c.DeleteConversation(ctx, convID, b.peerPhone(convID))
	case "block", "spam", "unblock":
		// block: 차단, spam: 차단하고 스팸 신고, unblock: 차단 해제
		act := gmproto.ConversationActionStatus_UNBLOCK
		var act5 *gmproto.ConversationAction5
		if action != "unblock" {
			act5 = &gmproto.ConversationAction5{Field2: true}
			act = gmproto.ConversationActionStatus_BLOCK
			if action == "spam" {
				act = gmproto.ConversationActionStatus_BLOCK_AND_REPORT
			}
		}
		data := &gmproto.DeleteConversationData{ConversationID: convID}
		if phone := b.peerPhone(convID); phone != "" {
			data.Phone = &phone
		}
		resp, err := c.UpdateConversation(ctx, &gmproto.UpdateConversationRequest{
			Action:         act,
			ConversationID: convID,
			Action5:        act5,
			Data:           &gmproto.UpdateConversationRequest_DeleteData{DeleteData: data},
		})
		if err != nil {
			return err
		}
		if !resp.GetSuccess() {
			return errors.New("휴대폰이 요청을 처리하지 못했습니다")
		}
		return nil
	case "mute", "unmute":
		st := gmproto.ConversationMuteStatus_MUTE
		if action == "unmute" {
			st = gmproto.ConversationMuteStatus_UNMUTE
		}
		_, err = c.UpdateConversation(ctx, &gmproto.UpdateConversationRequest{
			ConversationID: convID,
			Data: &gmproto.UpdateConversationRequest_UpdateData{UpdateData: &gmproto.UpdateConversationData{
				ConversationID: convID,
				Data:           &gmproto.UpdateConversationData_Mute{Mute: st},
			}},
		})
		return err
	case "rename":
		// RCS 그룹 대화만 이름을 바꿀 수 있다
		name = strings.TrimSpace(name)
		if name == "" {
			return errors.New("그룹 이름을 입력해 주세요")
		}
		resp, err := c.UpdateConversation(ctx, &gmproto.UpdateConversationRequest{
			Action:         gmproto.ConversationActionStatus_RENAME_GROUP,
			ConversationID: convID,
			Data:           &gmproto.UpdateConversationRequest_RenameData{RenameData: &gmproto.RenameGroupData{Name: name}},
		})
		if err != nil {
			return err
		}
		if !resp.GetSuccess() {
			return errors.New("휴대폰이 이름 변경을 처리하지 못했습니다")
		}
		return nil
	case "archive", "unarchive":
		st := gmproto.ConversationStatus_ARCHIVED
		if action == "unarchive" {
			st = gmproto.ConversationStatus_ACTIVE
		}
		_, err = c.UpdateConversation(ctx, &gmproto.UpdateConversationRequest{
			ConversationID: convID,
			Data: &gmproto.UpdateConversationRequest_UpdateData{UpdateData: &gmproto.UpdateConversationData{
				ConversationID: convID,
				Data:           &gmproto.UpdateConversationData_Status{Status: st},
			}},
		})
		return err
	}
	return fmt.Errorf("unknown action %q", action)
}

// ───────────────────────── 전송 ─────────────────────────

type sendArgs struct {
	ConvID  string `json:"convId"`
	TmpID   string `json:"tmpId"`
	Text    string `json:"text"`
	Path    string `json:"path"`
	Mime    string `json:"mime"`
	ReplyTo string `json:"replyTo"`
	// 보낼 SIM 의 participantId (듀얼 SIM 에서 직접 고른 경우). 비면 대화의 기본 SIM.
	SimID string `json:"simId"`
}

func sendMessage(ctx context.Context, a sendArgs) (any, error) {
	c, err := b.cli()
	if err != nil {
		return nil, err
	}
	b.mu.Lock()
	conv := b.convs[a.ConvID]
	b.mu.Unlock()
	if conv == nil {
		conv, err = c.GetConversation(ctx, a.ConvID)
		if err != nil {
			return nil, fmt.Errorf("대화 정보를 가져오지 못했습니다: %w", err)
		}
		b.storeConv(conv)
	}
	if a.TmpID == "" {
		a.TmpID = fmt.Sprintf("tmp_%d", time.Now().UnixNano())
	}
	var infos []*gmproto.MessageInfo
	if a.Path != "" {
		data, err := os.ReadFile(a.Path)
		if err != nil {
			return nil, err
		}
		mime := a.Mime
		if mime == "" {
			mime = http.DetectContentType(data)
		}
		media, err := c.UploadMedia(ctx, data, filepath.Base(a.Path), mime)
		if err != nil {
			return nil, fmt.Errorf("첨부 파일 업로드 실패: %w", err)
		}
		infos = append(infos, &gmproto.MessageInfo{Data: &gmproto.MessageInfo_MediaContent{MediaContent: media}})
	}
	if strings.TrimSpace(a.Text) != "" {
		infos = append(infos, &gmproto.MessageInfo{Data: &gmproto.MessageInfo_MessageContent{
			MessageContent: &gmproto.MessageContent{Content: a.Text},
		}})
	}
	if len(infos) == 0 {
		return nil, errors.New("보낼 내용이 없습니다")
	}
	outgoingID := conv.GetDefaultOutgoingID()
	b.mu.Lock()
	sim := b.sims[outgoingID]
	if a.SimID != "" {
		if chosen, ok := b.sims[a.SimID]; ok {
			sim = chosen
			outgoingID = a.SimID
		}
	}
	b.mu.Unlock()
	simPayload := sim.GetSIMData().GetSIMPayload()
	if simPayload == nil {
		simPayload = b.simPayloadFor(a.ConvID)
	}
	req := &gmproto.SendMessageRequest{
		ConversationID: a.ConvID,
		MessagePayload: &gmproto.MessagePayload{
			TmpID:          a.TmpID,
			ConversationID: a.ConvID,
			ParticipantID:  outgoingID,
			TmpID2:         a.TmpID,
			MessageInfo:    infos,
		},
		SIMPayload: simPayload,
		TmpID:      a.TmpID,
	}
	if a.ReplyTo != "" {
		req.Reply = &gmproto.ReplyPayload{MessageID: a.ReplyTo}
	}
	resp, err := c.SendMessage(ctx, req)
	if err != nil {
		return nil, err
	}
	if resp.GetStatus() != gmproto.SendMessageResponse_SUCCESS {
		return nil, fmt.Errorf("휴대폰이 전송을 거부했습니다 (%s)", resp.GetStatus())
	}
	return map[string]any{"tmpId": a.TmpID}, nil
}

func emojiType(e string) gmproto.EmojiType {
	switch e {
	case "👍":
		return gmproto.EmojiType_LIKE
	case "😍", "❤️", "❤":
		return gmproto.EmojiType_LOVE
	case "😂":
		return gmproto.EmojiType_LAUGH
	case "😮":
		return gmproto.EmojiType_SURPRISED
	case "😥", "😢":
		return gmproto.EmojiType_SAD
	case "😠":
		return gmproto.EmojiType_ANGRY
	case "👎":
		return gmproto.EmojiType_DISLIKE
	}
	return gmproto.EmojiType_CUSTOM
}

// ───────────────────────── JSON 변환 ─────────────────────────

func convJSON(c *gmproto.Conversation) map[string]any {
	parts := make([]map[string]any, 0, len(c.GetParticipants()))
	for _, p := range c.GetParticipants() {
		parts = append(parts, map[string]any{
			"id":        p.GetID().GetParticipantID(),
			"number":    p.GetID().GetNumber(),
			"formatted": p.GetFormattedNumber(),
			"name":      p.GetFullName(),
			"first":     p.GetFirstName(),
			"color":     p.GetAvatarHexColor(),
			"isMe":      p.GetIsMe(),
			"contactId": p.GetContactID(),
		})
	}
	lm := c.GetLatestMessage()
	return map[string]any{
		"id":            c.GetConversationID(),
		"name":          c.GetName(),
		"ts":            c.GetLastMessageTimestamp() / 1000,
		"unread":        c.GetUnread(),
		"isGroup":       c.GetIsGroupChat(),
		"preview":       lm.GetDisplayContent(),
		"previewFromMe": lm.GetFromMe() != 0,
		"previewName":   lm.GetDisplayName(),
		"status":        c.GetStatus().String(),
		"readOnly":      c.GetReadOnly(),
		"color":         c.GetAvatarHexColor(),
		"outgoingId":    c.GetDefaultOutgoingID(),
		"participants":  parts,
		"type":          c.GetType().String(),
		"pinned":        c.GetPinned(),
		"latestMsgId":   c.GetLatestMessageID(),
		"avatarUrl":     c.GetGroupAvatarURL(),
	}
}

func msgJSON(m *gmproto.Message) map[string]any {
	var texts []string
	media := make([]map[string]any, 0)
	addMedia := func(mc *gmproto.MediaContent, partID string) {
		if mc == nil {
			return
		}
		media = append(media, map[string]any{
			"partId":   partID,
			"mediaId":  mc.GetMediaID(),
			"key":      base64.StdEncoding.EncodeToString(mc.GetDecryptionKey()),
			"thumbId":  mc.GetThumbnailMediaID(),
			"thumbKey": base64.StdEncoding.EncodeToString(mc.GetThumbnailDecryptionKey()),
			"mime":     mc.GetMimeType(),
			"name":     mc.GetMediaName(),
			"size":     mc.GetSize(),
			"w":        mc.GetDimensions().GetWidth(),
			"h":        mc.GetDimensions().GetHeight(),
		})
	}
	for _, info := range m.GetMessageInfo() {
		switch d := info.GetData().(type) {
		case *gmproto.MessageInfo_MessageContent:
			if t := d.MessageContent.GetContent(); t != "" {
				texts = append(texts, t)
			}
		case *gmproto.MessageInfo_MediaContent:
			addMedia(d.MediaContent, info.GetActionMessageID())
		case *gmproto.MessageInfo_LocationContent:
			if t := d.LocationContent.GetMessageContent().GetContent(); t != "" {
				texts = append(texts, t)
			}
			addMedia(d.LocationContent.GetMediaContent(), info.GetActionMessageID())
		}
	}
	reactions := make([]map[string]any, 0)
	for _, r := range m.GetReactions() {
		emoji := r.GetData().GetUnicode()
		if emoji == "" {
			emoji = reactionFallback(r.GetData().GetType())
		}
		reactions = append(reactions, map[string]any{
			"emoji":        emoji,
			"participants": r.GetParticipantIDs(),
		})
	}
	status := m.GetMessageStatus().GetStatus()
	out := map[string]any{
		"id":            m.GetMessageID(),
		"convId":        m.GetConversationID(),
		"participantId": m.GetParticipantID(),
		"ts":            m.GetTimestamp() / 1000,
		"status":        int(status),
		"statusName":    status.String(),
		"text":          strings.Join(texts, "\n"),
		"media":         media,
		"tmpId":         m.GetTmpID(),
		"reactions":     reactions,
		"replyTo":       m.GetReplyMessage().GetMessageID(),
		"subject":       m.GetSubject(),
		"senderName":    m.GetSenderParticipant().GetFullName(),
		"msgType":       m.GetType(),
	}
	return out
}

func reactionFallback(t gmproto.EmojiType) string {
	switch t {
	case gmproto.EmojiType_LIKE:
		return "👍"
	case gmproto.EmojiType_LOVE:
		return "😍"
	case gmproto.EmojiType_LAUGH:
		return "😂"
	case gmproto.EmojiType_SURPRISED:
		return "😮"
	case gmproto.EmojiType_SAD:
		return "😥"
	case gmproto.EmojiType_ANGRY:
		return "😠"
	case gmproto.EmojiType_DISLIKE:
		return "👎"
	}
	return "❓"
}
