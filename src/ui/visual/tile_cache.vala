namespace Singularity.Widgets {

    public class TileCache : Object {
        public delegate void DrawTile (Cairo.Context cr, double x, double y, double width, double height);

        private class Tile {
            public Gdk.Texture texture;
            public uint64 used;
        }

        private Gee.HashMap<string, Tile> tiles = new Gee.HashMap<string, Tile> ();
        private double scale = 0;
        private uint64 frame = 0;

        public int tile_size { get; construct; }
        public int max_tiles { get; set; default = 256; }
        public int rendered_last_frame { get; private set; default = 0; }
        public int reused_last_frame { get; private set; default = 0; }

        public TileCache (int tile_size = 256) {
            Object (tile_size: tile_size);
        }

        public void invalidate () {
            tiles.clear ();
        }

        public void invalidate_area (double x, double y, double width, double height) {
            int t = tile_size;
            int i0 = (int) Math.floor (x / t), i1 = (int) Math.floor ((x + width) / t);
            int j0 = (int) Math.floor (y / t), j1 = (int) Math.floor ((y + height) / t);
            for (int i = i0; i <= i1; i++) {
                for (int j = j0; j <= j1; j++) tiles.unset (key (i, j));
            }
        }

        private static string key (int i, int j) {
            return "%d,%d".printf (i, j);
        }

        public static double device_scale (Gtk.Widget widget) {
            var native = widget.get_native ();
            var surface = native != null ? native.get_surface () : null;
            if (surface != null) return surface.get_scale ();
            return widget.get_scale_factor ();
        }

        public static double snap (double value, double scale) {
            return Math.round (value * scale) / scale;
        }

        private Gdk.Texture render (int i, int j, Gtk.Widget widget, DrawTile draw) {
            int t = tile_size;
            int px = (int) Math.ceil (t * scale);
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, px, px);
            var cr = new Cairo.Context (surface);
            cr.scale (scale, scale);
            cr.translate (-i * t, -j * t);
            cr.rectangle (i * t, j * t, t, t);
            cr.clip ();
            draw (cr, i * t, j * t, t, t);
            surface.flush ();
            int stride = surface.get_stride ();
            unowned uint8[] data = (uint8[]) surface.get_data ();
            data.length = stride * px;
            return new Gdk.MemoryTexture (px, px, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, new Bytes (data), stride);
        }

        private void trim () {
            if (tiles.size <= max_tiles) return;
            var order = new Gee.ArrayList<string> ();
            order.add_all (tiles.keys);
            order.sort ((a, b) => {
                uint64 x = tiles[a].used, y = tiles[b].used;
                return x < y ? -1 : (x > y ? 1 : 0);
            });
            int drop = tiles.size - max_tiles;
            for (int k = 0; k < drop; k++) tiles.unset (order[k]);
        }

        public void snapshot (Gtk.Snapshot snapshot, Gtk.Widget widget, Graphene.Rect viewport, double content_x, double content_y, DrawTile draw) {
            double s = device_scale (widget);
            if (s != scale) {
                scale = s;
                tiles.clear ();
            }
            frame++;
            int t = tile_size;
            double vx = snap (viewport.origin.x, scale), vy = snap (viewport.origin.y, scale);
            double vw = viewport.size.width, vh = viewport.size.height;
            double cx = snap (content_x, scale), cy = snap (content_y, scale);
            int i0 = (int) Math.floor (cx / t), i1 = (int) Math.floor ((cx + vw) / t);
            int j0 = (int) Math.floor (cy / t), j1 = (int) Math.floor ((cy + vh) / t);
            int made = 0, reused = 0;
            snapshot.push_clip (Graphene.Rect ().init ((float) vx, (float) vy, (float) vw, (float) vh));
            for (int j = j0; j <= j1; j++) {
                for (int i = i0; i <= i1; i++) {
                    string k = key (i, j);
                    var tile = tiles[k];
                    if (tile == null) {
                        tile = new Tile ();
                        tile.texture = render (i, j, widget, draw);
                        tiles[k] = tile;
                        made++;
                    } else {
                        reused++;
                    }
                    tile.used = frame;
                    var rect = Graphene.Rect ().init ((float) (vx + i * t - cx), (float) (vy + j * t - cy), (float) t, (float) t);
                    snapshot.append_scaled_texture (tile.texture, Gsk.ScalingFilter.NEAREST, rect);
                }
            }
            snapshot.pop ();
            rendered_last_frame = made;
            reused_last_frame = reused;
            trim ();
        }
    }
}
