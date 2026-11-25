-- Trips dropped off in or on each building, as ST_Intersects(dropoff, building):
-- a Point/Polygon join, with the Point first, that matches a point on a ring,
-- grouped, ordered and limited.
SELECT b.b_buildingkey,
       count(*) AS trips,
       max(ST_Area(ST_GeomFromBinary(b.b_boundary))) AS area
FROM trip t
JOIN building b ON ST_Intersects(ST_GeomFromBinary(t.t_dropoffloc), ST_GeomFromBinary(b.b_boundary))
GROUP BY b.b_buildingkey
ORDER BY trips DESC, b.b_buildingkey
LIMIT 20
