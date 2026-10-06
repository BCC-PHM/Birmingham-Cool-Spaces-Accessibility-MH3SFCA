setwd("~/R_project/accesbility to cooling spaces")

library(tidyverse)
library(sf)   
library(readxl)
library(tmap)

#=========================================================================
#load data
lsoa_bham = read_sf("data/boundaries/boundaries-lsoa-2021-birmingham.geojson")

catchment_full =read_rds("data/processed/02_catchement_full.rds")

lsoa_pop = read_excel("data/sapelsoasyoa20222024.xlsx", 
                       sheet = "Mid-2024 LSOA 2021", skip = 3)


bham_lsoa_map = read_sf("data/boundaries/boundaries-lsoa-2021-birmingham.geojson")

coolspace_coord = readRDS("C:/Users/chung/Documents/R_project/accesbility to cooling spaces/data/processed/coolspace_screen.rds")
#=========================================================================
 
bham_lsoa_pop = lsoa_pop %>% 
  janitor::clean_names() %>% 
  filter(lsoa_2021_code %in% lsoa_bham$lsoa21cd) %>% 
  select(-c(paste0("f",0:64), paste0("m", 0:64))) %>% 
  pivot_longer(cols = c(-lad_2023_code,-lad_2023_name,-lsoa_2021_code,-lsoa_2021_name),
               names_to = "scenario",
               values_to = "pop") %>% 
  mutate(scenario = ifelse(scenario == "total", "heat_adult", "heat_elderly")) %>% 
  group_by(lsoa_2021_code,lsoa_2021_name ,scenario ) %>% 
  summarise(pop = sum(pop, na.rm = TRUE),
            .groups = "drop") 


#=========================================================================
#MHV3SFCA
#w is the Luo & Qi's zone weights
#we will use slide method (beta)

catchment_full_processed = catchment_full %>% 
  select(-LSOA21NM) %>% 
  left_join(lsoa_bham %>% select(lsoa21cd, lsoa21nm) %>% st_drop_geometry(),
            by = c("LSOA21CD" = "lsoa21cd")) %>% 
  relocate(lsoa21nm, .after = "LSOA21CD") %>% 
  rename(LSOA21NM = lsoa21nm) %>% 
  left_join(bham_lsoa_pop, by = c("LSOA21CD" = "lsoa_2021_code", "scenario")) %>% 
  #step1 Huff is the probability of interaction 
  mutate(beta = -(15)^2/log(0.01),
         w = ifelse(is.na(time), 0, exp(-(time)^2/beta)),
         Huff= weekly_afternoon_hours*w) %>% 
  group_by(scenario,LSOA21CD,LSOA21NM) %>% 
  mutate(Huff_denom = ifelse(is.na(Huff), NA, sum(Huff)),
         Huff_p = ifelse(is.na(Huff_denom), NA, Huff/Huff_denom)) %>% 
  ungroup() %>% 
  #step2 R is the supply–demand-ratio
  group_by(name_spce,scenario) %>% 
  mutate(R_denom = sum(Huff_p*w*pop),
         R = weekly_afternoon_hours/R_denom) %>% 
  ungroup() %>% 
  #step3 A is the weekly afternoon cool-space opening hours available per person
  mutate(A = Huff_p*R*w) %>% 
  group_by(scenario,LSOA21CD,LSOA21NM) %>% 
  summarise(A_sum = sum(A, na.rm=TRUE),
            pop = first(pop),
            .groups = "drop")
  
  
#---------------------------------------------------
#check 1: every lsoa appears once per scenario
#---------------------------------------------------
catchment_full_processed %>% 
  count(scenario)
sum(is.na(catchment_full_processed$A_sum))
sum(is.na(catchment_full_processed$pop))

#---------------------------------------------------
#check 2: huff shares sum to 1 for lsoas with access
#---------------------------------------------------
catchment_full %>% 
  filter(!no_access) %>% 
  mutate(beta = -(15)^2/log(0.01), 
         w = exp(-(time)^2/beta), 
         Huff = weekly_afternoon_hours*w) %>% 
  group_by(scenario, LSOA21CD) %>% 
  summarise(total_p = sum(Huff/sum(Huff)), 
            .groups = "drop") %>% 
  summary()

#---------------------------------------------------
#check 3: population-weighted access equals total reachable supply
#---------------------------------------------------
check_access = catchment_full_processed %>% 
  group_by(scenario) %>% 
  summarise(total_access = sum(A_sum * pop))

check_supply = catchment_full %>% 
  filter(!no_access) %>% 
  distinct(scenario, name_spce, weekly_afternoon_hours) %>% 
  group_by(scenario) %>% 
  summarise(total_supply = sum(weekly_afternoon_hours))

left_join(check_access, check_supply, by = "scenario") %>% 
  mutate(diff = total_access - total_supply)

#=========================================================================
#plot the results 
pal = c("#1b8a8f", "#8cc8cf", "#f1d58a", "#f3a583", "#e4531c")


#polygon layer data 
map_adult_data = bham_lsoa_map %>% 
  left_join(catchment_full_processed, by = c("lsoa21cd"="LSOA21CD")) %>% 
  filter(scenario == "heat_adult") %>% 
  mutate(n_tile = ifelse(A_sum == 0, NA, ntile(ifelse(A_sum == 0, NA, A_sum), 5))) %>% 
  group_by(n_tile) %>% 
  mutate(tile_max = max(A_sum)) %>% 
  ungroup() %>% 
  mutate(n_tile = factor(n_tile)) 

#point layer data
map_adult_coolspace_coord = coolspace_coord %>% 
  filter(space_name %in% (catchment_full %>% filter(scenario == "heat_adult") %>% distinct(name_spce) %>% pull(name_spce))) %>% 
  select(space_name, longitude,latitude) %>%
  left_join(catchment_full %>% distinct(name_spce, hours_candidate), by = c("space_name" = "name_spce")) %>% 
  mutate(hours_candidate = str_extract(hours_candidate, "Tier [12]")) %>% 
  st_as_sf(coords = c("longitude", "latitude"), crs =4326)



tile_labs = map_adult_data %>% 
  st_drop_geometry() %>% 
  filter(!is.na(n_tile)) %>% 
  distinct(n_tile, tile_max) %>% 
  arrange(n_tile) %>% 
  mutate(lab = paste0("\u2264", round(tile_max,6)))


catchment_full_processed_map = tm_shape(map_adult_data)+
  tm_polygons(
    fill        = "n_tile",
    fill.scale  = tm_scale_categorical(values = c("#1b8a8f", "#8cc8cf", "#f1d58a", "#f3a583", "#e4531c"), 
                                       labels = tile_labs$lab, 
                                       value.na = "white", 
                                       label.na = "No access"),
    fill.legend = tm_legend(title = "Accessbility index"),
    col="grey70")+
  tm_shape(map_adult_coolspace_coord)+
  tm_symbols(
    fill         = "hours_candidate",
    fill.scale   = tm_scale_categorical(values = c("black", "grey55")),
    fill.legend  = tm_legend(title = "Cool spaces"),
    shape        = "hours_candidate",
    shape.scale  = tm_scale_categorical(values = c(24, 21)),
    shape.legend = tm_legend_combine("fill"),
    size         = 0.45,
    col          = "white",
    lwd          = 0.4)+
  tm_layout(
    frame = FALSE,
    legend.position = tm_pos_in(pos.h = 0.02, pos.v = 1.01),
    legend.frame = FALSE,
    legend.text.size = 0.5,
    legend.title.size = 0.6,
    inner.margins = c(0.07, 0, 0.01, 0)
  )+
  tm_title("Potential spatial accessbility of weekly afternoon \ncool-space hours per person in Birmingham", size = 1.5)+
  tm_compass(
    type = "8star",
    size = 4,
    position = c("RIGHT", "bottom"),
    color.light = "white"
  ) +
  tm_credits(
    text = paste(
      "Contains OS data \u00A9 Crown copyright and database right",
      format(Sys.Date(), "%Y"),
      ". Source:\nOffice for National Statistics licensed under the Open Government Licence v.3.0."
    ),
    position = c("LEFT", "BOTTOM")
  )

tmap_save(catchment_full_processed_map,
          filename = "figs/cool_spaces_spatial_accessbility.png",
          width = 5,
          height = 6,
          units = "in",
          dpi = 600)
  














