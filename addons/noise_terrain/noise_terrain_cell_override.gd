class_name NoiseTerrainCellOverride
extends Resource
## Drops hand-made terrain into one cell of the world. The texture is read as a height map
## (red channel, black = low, white = high). It can be a NoiseTexture2D with its own unique
## noise, or any painted image.

enum Mode {
	REPLACE, ## The cell's height comes from the texture alone.
	ADD, ## The texture is added on top of the normal noise terrain.
}

## Which cell to replace, counted in whole cells (NoiseTerrainSettings.cell_size) from the world origin.
@export var cell: Vector2i = Vector2i.ZERO
## Height map for the cell.
@export var height_map: Texture2D
@export var mode: Mode = Mode.REPLACE
## Height in metres of a black pixel.
@export var base_height: float = 0.0
## Metres between a black pixel and a white pixel.
@export var height_scale: float = 600.0
## Fraction of the cell (0 to 0.5) used to blend back into the surrounding terrain, so there is no seam.
@export_range(0.02, 0.5) var blend_margin: float = 0.2
