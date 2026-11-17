-- Per-trip spatial functions over every trip: the distance between pickup and
-- dropoff, its minimum X, a CASE guard and a wrapper beside a constant, under a
-- spatial filter and a global aggregation.
SELECT count(*) AS trips,
       sum(ST_Distance(ST_GeomFromBinary(t_pickuploc), ST_GeomFromBinary(t_dropoffloc))) AS total_distance,
       avg(round(ST_Distance(ST_GeomFromBinary(t_pickuploc), ST_GeomFromBinary(t_dropoffloc)), 3)) AS mean_rounded,
       max(ST_XMin(ST_GeomFromBinary(t_pickuploc))) AS max_pickup_x,
       sum(CASE WHEN ST_XMin(ST_GeomFromBinary(t_pickuploc)) > 0
                THEN ST_Distance(ST_GeomFromBinary(t_pickuploc), ST_GeomFromBinary(t_dropoffloc)) END) AS east_distance
FROM trip
WHERE ST_Distance(ST_GeomFromBinary(t_pickuploc), ST_GeomFromBinary(t_dropoffloc)) > 0.01
