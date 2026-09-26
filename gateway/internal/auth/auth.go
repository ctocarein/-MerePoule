package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/argon2"
)

const (
	MaxPINFailures = 5         // par appareil et par fenêtre
	PINWindow      = time.Hour // fenêtre du décompte des échecs
	EnrollmentTTL  = 5 * time.Minute
)

// Paramètres Argon2id : recommandation RFC 9106 pour une mémoire modérée.
const (
	argonTime    = 3
	argonMemory  = 64 * 1024
	argonThreads = 2
	argonKeyLen  = 32
)

// NewSecret renvoie n octets aléatoires en base64 URL.
func NewSecret(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand ne manque jamais d'entropie sous Windows
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// Hash est l'empreinte stockée d'un jeton ou d'un code.
func Hash(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// codeAlphabet exclut les caractères qui se confondent à la lecture (0, O, 1, I).
const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// NewEnrollmentCode renvoie un code à usage unique, lisible : XXXXX-XXXXX.
func NewEnrollmentCode() string {
	b := make([]byte, 10)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	var sb strings.Builder
	for i, c := range b {
		if i == 5 {
			sb.WriteByte('-')
		}
		sb.WriteByte(codeAlphabet[int(c)%len(codeAlphabet)])
	}
	return sb.String()
}

// NormalizeCode rend un code saisi comparable à celui émis.
func NormalizeCode(code string) string {
	code = strings.ToUpper(code)
	return strings.NewReplacer("-", "", " ", "").Replace(code)
}

// ValidPIN : 6 à 12 chiffres.
func ValidPIN(pin string) bool {
	if len(pin) < 6 || len(pin) > 12 {
		return false
	}
	for _, c := range pin {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// HashPIN renvoie "argon2id$<sel>$<empreinte>", sel et empreinte en base64.
func HashPIN(pin string) (string, error) {
	if !ValidPIN(pin) {
		return "", fmt.Errorf("PIN invalide : 6 à 12 chiffres")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(pin), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return "argon2id$" + base64.RawStdEncoding.EncodeToString(salt) + "$" + base64.RawStdEncoding.EncodeToString(key), nil
}

// VerifyPIN compare en temps constant.
func VerifyPIN(encoded, pin string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 3 || parts[0] != "argon2id" {
		return false
	}
	salt, err1 := base64.RawStdEncoding.DecodeString(parts[1])
	want, err2 := base64.RawStdEncoding.DecodeString(parts[2])
	if err1 != nil || err2 != nil {
		return false
	}
	got := argon2.IDKey([]byte(pin), salt, argonTime, argonMemory, argonThreads, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}
