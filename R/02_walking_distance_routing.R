setwd("~/R_project/accesbility to cooling spaces")

library(tidyverse)
library(sf)   
#===================================================================
#load data
coolspaces_list = read_rds("data/processed/coolspace_review_list.rds")

pop_centriod = read_sf("data/boundaries/LSOA_PopCentroids_EW_2021_V4_-3471144733095659889.gpkg")

lsoa_bham = read_sf("data/boundaries/boundaries-lsoa-2021-birmingham.geojson")

#===================================================================
#turn coolspaces long lat to geometry
coolspaces_list = coolspaces_list %>% 
  st_as_sf(coords = c("longitude", "latitude"), crs =4326)


#===================================================================
#filter out bham lsoa centriod

bham_pop_ceentriod = pop_centriod %>% 
  filter(LSOA21CD %in%  lsoa_bham$lsoa21cd) %>% 
  st_transform(crs=4326)


#---------------------------------------------------
#candidate sites within straight-line reach
#---------------------------------------------------
max_m = 15 * 60 * 1.39

near = st_is_within_distance(st_transform(bham_pop_ceentriod, 27700), st_transform(coolspaces_list, 27700), dist = max_m)


o_chk = bham_pop_ceentriod %>% 
  filter(LSOA21CD == "E01009238")
d_chk = coolspaces_list %>% 
  filter(space_name %in% c("Perry Beeches Baptist Church", "Tower Hill Library"))

st_distance(st_transform(o_chk, 27700), st_transform(d_chk, 27700))

#===================================================
#loop over every lsoa
#===================================================

OD_list = list()

for (i in seq_len(nrow(bham_pop_ceentriod))) {

#---------------------------------------------------
#pick one lsoa and its candidate cool spaces
#---------------------------------------------------
origin = st_coordinates(st_transform(bham_pop_ceentriod[i, ], 4326))
destination = st_coordinates(st_transform(coolspaces_list[near[[i]], ], 4326))

if (length(destination)==0){
  
  OD_table = data.frame(LSOA21CD = bham_pop_ceentriod[i, ]$LSOA21CD,
                        LSOA21NM = lsoa_bham$lsoa21nm[lsoa_bham$lsoa21cd == bham_pop_ceentriod[i, ]$LSOA21CD],
                        name_spce = NA,
                        distance = NA,
                        durations = NA )%>% 
    mutate(normal_day_durations        = NA,
           adult_heat_day_durations    = NA,
           elderly_heat_day_durations  = NA)
  
  
} else{

#---------------------------------------------------
#build the table request: source 0, destinations 1..n
#---------------------------------------------------
coords =  paste0(c(origin[,1], destination[, 1]), ",", c(origin[, 2], destination[, 2]),collapse = ";")
dst = paste(seq_len(nrow(destination)), collapse = ";")
url = paste0("http://localhost:5001/table/v1/foot/", coords, "?sources=0&destinations=", dst, "&annotations=duration,distance")


#---------------------------------------------------
#send the request and read the result
#---------------------------------------------------
res = fromJSON(content(GET(url), as = "text", encoding = "UTF-8"))
res$code
res$distances
res$durations


OD_table = data.frame(LSOA21CD = bham_pop_ceentriod[i, ]$LSOA21CD,
                      LSOA21NM = lsoa_bham$lsoa21nm[lsoa_bham$lsoa21cd == bham_pop_ceentriod[i, ]$LSOA21CD],
           name_spce = coolspaces_list[near[[i]], ]$space_name,
           distance = as.vector(res$distances),
           durations = as.vector(res$durations)) %>% 
  mutate(normal_day_durations        = distance / 1.39 / 60,
         adult_heat_day_durations    = distance / (1.39 * 0.91) / 60,
         elderly_heat_day_durations  = distance / 0.89 / 60)

}

OD_list[[i]] = OD_table

}

OD_all = bind_rows(OD_list)


#===================================================
#straight-line distance for every lsoa-cool space pair
#===================================================
lsoa_27700 = st_transform(bham_pop_ceentriod, 27700)
cool_27700 = st_transform(coolspaces_list, 27700)

o_row = match(OD_all$LSOA21CD, lsoa_27700$LSOA21CD)
d_row = match(OD_all$name_spce, cool_27700$space_name)
ok = !is.na(d_row)

OD_all$straight = NA
OD_all$straight[ok] = as.numeric(st_distance(lsoa_27700[o_row[ok], ], cool_27700[d_row[ok], ], by_element = TRUE))

#---------------------------------------------------
#circuity ratio and missing-link flag
#---------------------------------------------------
OD_all = OD_all %>% 
  mutate(circuity = distance / straight, 
         flag_missing_link = !is.na(circuity) & circuity > 3)

#---------------------------------------------------
#how many pairs and lsoas are affected
#---------------------------------------------------
sum(OD_all$flag_missing_link)
OD_all %>% 
  filter(!is.na(circuity)) %>% 
  group_by(LSOA21CD, LSOA21NM) %>% 
  summarise(min_circuity = min(circuity), .groups = "drop") %>% 
  filter(min_circuity > 3) %>% 
  arrange(desc(min_circuity))

#---------------------------------------------------
#check flagged pairs against mapbox walking routes
#---------------------------------------------------
mb_token = Sys.getenv("MAPBOX_TOKEN")

to_check = OD_all %>% 
  filter(flag_missing_link) %>% 
  mutate(o_row = match(LSOA21CD, bham_pop_ceentriod$LSOA21CD), d_row = match(name_spce, coolspaces_list$space_name))

lsoa_ll = st_coordinates(st_transform(bham_pop_ceentriod, 4326))
cool_ll = st_coordinates(st_transform(coolspaces_list, 4326))

mb_res = lapply(seq_len(nrow(to_check)), function(k) {
  o = lsoa_ll[to_check$o_row[k], ]
  d = cool_ll[to_check$d_row[k], ]
  url = paste0("https://api.mapbox.com/directions/v5/mapbox/walking/", o[1], ",", o[2], ";", d[1], ",", d[2], "?access_token=", mb_token)
  Sys.sleep(2)
  r = fromJSON(content(GET(url), as = "text", encoding = "UTF-8"))$routes
  data.frame(mapbox_m = r$distance[1], mapbox_s = r$duration[1])
})
to_check = bind_cols(to_check, bind_rows(mb_res))

#---------------------------------------------------
#remove leftover columns from earlier runs
#---------------------------------------------------
OD_all = OD_all %>% 
  select(-any_of(c("mapbox_m", "mapbox_s", "mapbox_min", "distance_adj", "distance_final")))

#---------------------------------------------------
#rebuild to_check and attach the mapbox results
#---------------------------------------------------
to_check = OD_all %>% 
  filter(flag_missing_link) %>% 
  mutate(o_row = match(LSOA21CD, bham_pop_ceentriod$LSOA21CD), d_row = match(name_spce, coolspaces_list$space_name))
to_check = bind_cols(to_check, bind_rows(mb_res))
#===================================================
#use mapbox distance for flagged pairs
#===================================================
OD_all = OD_all %>% 
  left_join(to_check %>% select(LSOA21CD, name_spce, mapbox_m, mapbox_s), by = c("LSOA21CD", "name_spce")) %>% 
  mutate(
    mapbox_min                 = mapbox_s / 60,
    distance_final             = if_else(flag_missing_link & !is.na(mapbox_m), pmin(distance, mapbox_m), distance),
    normal_day_durations       = distance_final / 1.39 / 60,
    adult_heat_day_durations   = distance_final / (1.39 * 0.91) / 60,
    elderly_heat_day_durations = distance_final / 0.89 / 60
  )


#===================================================
#15-minute catchment and zone weights by scenario
#===================================================

catchement_area = OD_all %>% 
  select(LSOA21CD, LSOA21NM, name_spce, distance_final, adult_heat_day_durations, elderly_heat_day_durations) %>% 
  pivot_longer(c(adult_heat_day_durations, elderly_heat_day_durations), 
               names_to = "scenario", 
               values_to = "time") %>% 
  mutate(scenario = recode(scenario, adult_heat_day_durations = "heat_adult", 
                           elderly_heat_day_durations = "heat_elderly")) %>% 
  filter(!is.na(time), time <= 15) %>% 
  mutate(w = case_when(
    time <= 5  ~ 1.00,
    time <= 10 ~ 0.68,
    TRUE       ~ 0.22
  ))


#---------------------------------------------------
#every lsoa in every scenario, including those with no cool space
#---------------------------------------------------

catchement_full = crossing(scenario = unique(catchement_area$scenario), LSOA21CD = lsoa_bham$lsoa21cd) %>% 
  left_join(catchement_area, by = c("scenario", "LSOA21CD")) %>% 
  mutate(no_access = is.na(name_spce)) %>% 
  left_join(coolspaces_list%>% select(space_name,hours_candidate,days_with_two_hours,weekly_afternoon_hours,
                                      weekly_hours_status) %>% st_drop_geometry(),
            by = c("name_spce" = "space_name"))



write_rds(catchement_full, "data/processed/02_catchement_full.rds")


























