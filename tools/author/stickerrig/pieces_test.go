package main

import (
	"image"
	"image/color"
	"testing"
)

func disc(img *image.RGBA, cx, cy, r int) {
	for y := cy - r; y <= cy+r; y++ {
		for x := cx - r; x <= cx+r; x++ {
			if (x-cx)*(x-cx)+(y-cy)*(y-cy) <= r*r {
				img.Set(x, y, color.RGBA{120, 60, 20, 255})
			}
		}
	}
}

func TestPiecesAreFoundAndCutApart(t *testing.T) {
	sheet := image.NewRGBA(image.Rect(0, 0, 300, 200))
	disc(sheet, 200, 50, 30) // top right
	disc(sheet, 50, 60, 30)  // top left, a little lower: same row
	disc(sheet, 100, 150, 25)
	disc(sheet, 128, 150, 3) // a wisp 0–2 px from the disc: the same piece
	disc(sheet, 280, 190, 2) // a crumb: no piece
	pieces := findPieces(sheet)
	if len(pieces) != 3 {
		t.Fatalf("want 3 pieces, got %d: %+v", len(pieces), pieces)
	}
	if pieces[0].box.Min.X > 30 || pieces[1].box.Min.X < 160 || pieces[2].box.Min.Y < 100 {
		t.Fatalf("not in reading order: %v %v %v", pieces[0].box, pieces[1].box, pieces[2].box)
	}
	img, ok := pieceAt(sheet, image.Pt(100, 150))
	if !ok || img.Bounds().Dx() < 55 || img.Bounds().Dx() > 64 {
		t.Fatalf("the bottom piece with its wisp: got %v", img.Bounds())
	}
	if _, ok := pieceAt(sheet, image.Pt(290, 10)); ok {
		t.Fatal("a point far from every piece names none")
	}
}

func TestSilhouetteGrowsByTheBorder(t *testing.T) {
	art := image.NewRGBA(image.Rect(0, 0, 21, 21))
	disc(art, 10, 10, 10)
	s := silhouette(art, 5)
	if s.Bounds().Dx() != 21+12 {
		t.Fatalf("padded by radius+1 on each side: %v", s.Bounds())
	}
	// The centre and 4 px beyond the art's edge are white; 8 px beyond is clear.
	if a := s.RGBAAt(16, 16).A; a != 255 {
		t.Fatalf("centre alpha %d", a)
	}
	if a := s.RGBAAt(16+10+4, 16).A; a < 200 {
		t.Fatalf("inside the border: alpha %d", a)
	}
	if a := s.RGBAAt(16+10+8, 16).A; a != 0 {
		t.Fatalf("beyond the border: alpha %d", a)
	}
}
