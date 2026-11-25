-- Polygon functions over every building under CASE and IF guards whose
-- conditions test the BIGINT key: a vertex count and a centroid, a geometry
-- result read back through ST_X and ST_Y, under a global aggregation.
SELECT count(*) AS buildings,
       sum(CASE WHEN b_buildingkey % 2 = 0 THEN ST_NumPoints(g) END) AS even_vertices,
       max(ST_X(IF(b_buildingkey % 3 = 0, ST_Centroid(g)))) AS max_centroid_x,
       min(ST_Y(CASE WHEN b_buildingkey % 3 = 0 THEN ST_Centroid(g) END)) AS min_centroid_y
FROM (SELECT b_buildingkey, ST_GeomFromBinary(b_boundary) AS g FROM building)
