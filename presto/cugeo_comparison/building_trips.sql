-- Trips picked up inside each building: a Point-in-Polygon join, the building's
-- area and the mean distance from its centroid to the pickups above the join,
-- grouped, ordered and limited.
SELECT b.b_buildingkey,
       count(*) AS trips,
       max(ST_Area(ST_GeomFromBinary(b.b_boundary))) AS area,
       avg(ST_Distance(ST_Centroid(ST_GeomFromBinary(b.b_boundary)), ST_GeomFromBinary(t.t_pickuploc))) AS mean_centroid_distance
FROM trip t
JOIN building b ON ST_Within(ST_GeomFromBinary(t.t_pickuploc), ST_GeomFromBinary(b.b_boundary))
GROUP BY b.b_buildingkey
ORDER BY trips DESC, b.b_buildingkey
LIMIT 20
