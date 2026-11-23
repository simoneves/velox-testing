-- Trips picked up inside each building, as ST_Contains(building, pickup): a
-- Point-in-Polygon join with the building's vertex count and centroid
-- coordinates above it, grouped, ordered and limited.
SELECT b.b_buildingkey,
       count(*) AS trips,
       max(ST_NumPoints(ST_GeomFromBinary(b.b_boundary))) AS vertices,
       max(ST_X(ST_Centroid(ST_GeomFromBinary(b.b_boundary)))) AS centroid_x,
       max(ST_Y(ST_Centroid(ST_GeomFromBinary(b.b_boundary)))) AS centroid_y
FROM trip t
JOIN building b ON ST_Contains(ST_GeomFromBinary(b.b_boundary), ST_GeomFromBinary(t.t_pickuploc))
GROUP BY b.b_buildingkey
ORDER BY trips DESC, b.b_buildingkey
LIMIT 20
