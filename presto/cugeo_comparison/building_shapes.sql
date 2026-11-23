-- Polygon functions over every building: vertex count, centroid X, area and
-- minimum X, under a spatial filter and a global aggregation.
SELECT count(*) AS buildings,
       sum(ST_NumPoints(g)) AS vertices,
       avg(ST_X(ST_Centroid(g))) AS mean_centroid_x,
       sum(ST_Area(g)) AS total_area,
       min(ST_XMin(g)) AS min_x
FROM (SELECT ST_GeomFromBinary(b_boundary) AS g FROM building)
WHERE ST_Area(g) > 0
