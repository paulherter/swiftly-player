import CVLC
import CBildbruecke

// Nur zum Fragen: jeder Typ absichtlich als Int deklariert, damit der
// Übersetzer den richtigen nennt. Fliegt gleich wieder raus.
func probe() {
    let a: Int = libvlc_new(0, nil)
    let m: Int = libvlc_media_new_location(a as! OpaquePointer, "x")
    let p: Int = libvlc_media_player_new_from_media(m as! OpaquePointer)
    let t: Int = libvlc_media_player_get_time(p as! OpaquePointer)
    let l: Int = libvlc_media_player_get_length(p as! OpaquePointer)
    let s: Int = libvlc_audio_get_track_description(p as! OpaquePointer)
    let b: Int = bildbruecke_neu()
    _ = (a, m, p, t, l, s, b)
}
