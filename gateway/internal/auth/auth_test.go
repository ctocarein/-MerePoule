package auth

import "testing"

func TestPIN(t *testing.T) {
	h, err := HashPIN("482913")
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyPIN(h, "482913") || VerifyPIN(h, "482914") {
		t.Fatal("vérification du PIN incorrecte")
	}
	h2, _ := HashPIN("482913")
	if h == h2 {
		t.Fatal("deux empreintes identiques : le sel ne change pas")
	}
	for _, bad := range []string{"", "12345", "12a456", "1234567890123"} {
		if ValidPIN(bad) {
			t.Fatalf("%q accepté comme PIN", bad)
		}
	}
}

func TestEnrollmentCode(t *testing.T) {
	c := NewEnrollmentCode()
	if len(c) != 11 || c[5] != '-' {
		t.Fatalf("format inattendu : %q", c)
	}
	if NormalizeCode(" "+c[:5]+" "+c[6:]) != NormalizeCode(c) {
		t.Fatal("un code saisi avec des espaces doit rester valable")
	}
}
