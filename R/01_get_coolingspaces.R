setwd("~/R_project/accesbility to cooling spaces")

library(tidyverse)
library(rvest)
library(httr2)
library(data.table)

dir.create("data/processed", recursive = TRUE, showWarnings = FALSE)

#==================================================
#scrape council spaces
#==================================================
bham_coolspaces = read_html(
  "https://www.birmingham.gov.uk/directory/73/warm_welcome_spaces_in_birmingham/category/1859"
)

individual_spaces = bham_coolspaces %>% 
  html_elements(xpath = "//*[@id='content']/nav/ul/li/a") %>% 
  html_attr("href") %>% 
  paste0("https://www.birmingham.gov.uk", .)

individual_spaces_list = vector("list", length(individual_spaces))

for (i in seq_along(individual_spaces)) {
  individual_page = read_html(individual_spaces[[i]])
  
  name = individual_page %>% 
    html_elements(xpath = "//*[@id='content']/h1") %>% 
    html_text()
  
  column = individual_page %>% 
    html_elements(xpath = "//*[@id='content']/dl/dt") %>% 
    html_text()
  
  value = individual_page %>% 
    html_elements(xpath = "//*[@id='content']/dl/dd") %>% 
    html_text2() %>% 
    str_squish()
  
  longlat = individual_page %>% 
    html_elements(xpath = "//*[@id='map_marker_location_772']") %>% 
    html_attr("value")
  
  if (length(longlat) == 0) longlat = NA_character_
  
  df = data.table::as.data.table(as.list(value))
  data.table::setnames(df, column)
  
  individual_spaces_list[[i]] = df %>% 
    mutate(space_name = name, Map = longlat) %>% 
    separate(Map, into = c("latitude", "longitude"), sep = ",", convert = TRUE) %>% 
    select(space_name, everything())
}

coolspaces = rbindlist(individual_spaces_list, fill = TRUE) %>% 
  as_tibble() %>% 
  mutate(council_row = row_number())

write_rds(coolspaces, "data/processed/coolspaces.rds")

coolspaces %>% 
  summarise(spaces = n(), missing_coordinates = sum(is.na(latitude) | is.na(longitude)))

#==================================================
#parse council opening hours
#==================================================
days = c("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
day_rx = paste0("(?:", paste(days, collapse = "|"), ")")
time_rx = "\\d{1,2}(?::\\d{2})?\\s*(?:am|pm)"
range_rx = paste0("(", time_rx, ")\\s*(?:to|-)\\s*(", time_rx, ")")
simple_range_rx = paste0(time_rx, "\\s*(?:to|-)\\s*", time_rx)

dayspec_rx = paste0(
  day_rx, "(?:\\s*(?:to|-)\\s*", day_rx, ")?",
  "(?:\\s*(?:,|and|&)\\s*", day_rx,
  "(?:\\s*(?:to|-)\\s*", day_rx, ")?)*"
)

block_rx = paste0(
  "(", dayspec_rx, ")\\s*[:,]?\\s*(",
  simple_range_rx,
  "(?:\\s*(?:,|and|&)\\s*", simple_range_rx, ")*)"
)

normalise_hours = function(x) {
  x = str_to_lower(coalesce(x, ""))
  x = str_replace_all(x, "[–—]", "-")
  x = str_replace_all(x, "\\b(midday|noon)\\b", "12:00pm")
  x = str_replace_all(x, "(\\d{1,2})\\.(\\d{2})", "\\1:\\2")
  x = str_replace_all(x, paste0("\\b(", paste(days, collapse = "|"), ")s\\b"), "\\1")
  x = str_replace_all(x, "\\bmon\\b", "monday")
  x = str_replace_all(x, "\\btues?\\b", "tuesday")
  x = str_replace_all(x, "\\bwed\\b", "wednesday")
  x = str_replace_all(x, "\\bthurs?\\b", "thursday")
  x = str_replace_all(x, "\\bfri\\b", "friday")
  x = str_replace_all(x, "\\bsat\\b", "saturday")
  str_replace_all(x, "\\bsun\\b", "sunday")
}

to_minutes = function(x) {
  hour = as.integer(str_extract(x, "^\\d{1,2}"))
  minute = coalesce(as.integer(str_match(x, ":(\\d{2})")[, 2]), 0L)
  (hour %% 12L + if_else(str_detect(x, "pm"), 12L, 0L)) * 60L + minute
}

expand_days = function(x) {
  parts = str_split(x, "\\s*(?:,|\\band\\b|&)\\s*")[[1]]
  
  map(parts, function(part) {
    ends = str_split(part, "\\s*(?:\\bto\\b|-)\\s*")[[1]]
    idx = match(ends, days)
    
    if (length(idx) == 2 && !anyNA(idx) && idx[1] <= idx[2]) {
      days[idx[1]:idx[2]]
    } else {
      ends[!is.na(idx)]
    }
  }) %>% 
    unlist() %>% 
    unique()
}

empty_hours = tibble(day = character(), open = integer(), close = integer())

parse_council_hours = function(x) {
  blocks = str_match_all(normalise_hours(x), block_rx)[[1]]
  if (nrow(blocks) == 0) return(empty_hours)
  
  map_dfr(seq_len(nrow(blocks)), function(i) {
    times = str_match_all(blocks[i, 3], range_rx)[[1]]
    
    intervals = tibble(
      open  = to_minutes(times[, 2]),
      close = to_minutes(times[, 3])
    ) %>% 
      filter(close > open)
    
    tidyr::expand_grid(day = expand_days(blocks[i, 2]), intervals)
  })
}

#==================================================
#turn council text into daily sessions
#==================================================
council_sites = coolspaces %>% 
  mutate(
    council_hours      = normalise_hours(`Opening hours`),
    n_time_ranges      = map_int(council_hours, ~nrow(str_match_all(.x, range_rx)[[1]])),
    n_parsed_ranges    = map_int(council_hours, function(x) {
      blocks = str_match_all(x, block_rx)[[1]]
      if (nrow(blocks) == 0) return(0L)
      sum(str_count(blocks[, 3], range_rx))
    }),
    irregular_schedule = str_detect(
      council_hours,
      "term[- ]time|school holiday|every other|every 2 weeks|fortnight|once a month|monthly|first |second |third |last "
    ),
    access_question    = str_detect(
      council_hours,
      "booking|book before|appointment|referral|students only|women only|over 60|over 50|chargeable"
    ),
    partial_parse      = n_time_ranges > n_parsed_ranges
  )

council_intervals = council_sites %>% 
  select(council_row, `Opening hours`) %>% 
  mutate(parsed = map(`Opening hours`, parse_council_hours)) %>% 
  select(council_row, parsed) %>% 
  unnest(parsed)

#--------------------------------------------------
#combine overlapping sessions; keep genuine breaks between sessions
#--------------------------------------------------
merged_intervals = council_intervals %>% 
  arrange(council_row, day, open) %>% 
  group_by(council_row, day) %>% 
  mutate(session = cumsum(open > lag(cummax(close), default = -1L))) %>% 
  group_by(council_row, day, session) %>% 
  summarise(open = min(open), close = max(close)) %>% 
  ungroup()

#==================================================
#screen GLA opening-day requirements
#==================================================
day_screen = merged_intervals %>% 
  group_by(council_row, day) %>% 
  summarise(
    tier1_day = any(open <= 10 * 60 & close >= 17 * 60),
    tier2_day = any(close > open)
  ) %>% 
  ungroup() %>% 
  group_by(council_row) %>% 
  summarise(tier1_days = sum(tier1_day), tier2_days = sum(tier2_day))

coolspace_screen = council_sites %>% 
  left_join(day_screen, by = "council_row") %>% 
  mutate(
    tier1_days      = coalesce(tier1_days, 0L),
    tier2_days      = coalesce(tier2_days, 0L),
    hours_candidate = case_when(
      tier1_days >= 5      ~ "Tier 1 hours candidate",
      tier2_days >= 2      ~ "Tier 2 hours candidate",
      n_parsed_ranges == 0 ~ "Hours unknown",
      TRUE                 ~ "Below hours threshold"
    ),
    review_required = irregular_schedule | access_question | partial_parse
  )

#==================================================
#aggregate council hours across a typical week
#==================================================
weekly_hours = merged_intervals %>% 
  mutate(
    open_hours      = (close - open) / 60,
    afternoon_hours = pmax(0, pmin(close, 17 * 60) - pmax(open, 12 * 60)) / 60
  ) %>% 
  group_by(council_row) %>% 
  summarise(
    weekly_open_hours      = sum(open_hours),
    weekly_afternoon_hours = sum(afternoon_hours),
    days_open              = n_distinct(day)
  )

daily_hours = merged_intervals %>% 
  group_by(council_row, day) %>% 
  summarise(open_hours = sum(close - open) / 60) %>% 
  pivot_wider(names_from = day, values_from = open_hours, values_fill = 0)

coolspace_screen = coolspace_screen %>% 
  left_join(weekly_hours, by = "council_row") %>% 
  left_join(daily_hours, by = "council_row") %>% 
  mutate(
    weekly_hours_status = case_when(
      n_parsed_ranges == 0 ~ "hours not parsed",
      partial_parse        ~ "incomplete parse: review",
      irregular_schedule   ~ "not a regular weekly schedule: review",
      TRUE                 ~ "provisional council hours"
    )
  )

stopifnot(nrow(coolspace_screen) == nrow(coolspaces))

#--------------------------------------------------
#save council-derived results before adding Google data
#--------------------------------------------------
write_rds(coolspace_screen, "data/processed/coolspace_screen.rds")

coolspace_screen %>% 
  count(hours_candidate, review_required)

coolspace_screen %>% 
  select(
    space_name, hours_candidate, weekly_open_hours, weekly_afternoon_hours,
    days_open, weekly_hours_status, any_of(days)
  )

#==================================================
#optional Google Places check
#==================================================
search_google = function(name, address) {
  key = Sys.getenv("GOOGLE_MAPS_API_KEY")
  if (!nzchar(key)) stop("GOOGLE_MAPS_API_KEY is missing from .Renviron")
  
  response = request("https://places.googleapis.com/v1/places:searchText") %>% 
    req_headers(
      `X-Goog-Api-Key`   = key,
      `X-Goog-FieldMask` = paste(
        "places.id", "places.displayName", "places.formattedAddress",
        "places.location", "places.businessStatus",
        "places.regularOpeningHours", sep = ","
      )
    ) %>% 
    req_body_json(list(
      textQuery    = paste(name, address, "Birmingham UK"),
      pageSize     = 3,
      languageCode = "en",
      regionCode   = "GB"
    )) %>% 
    req_perform() %>% 
    resp_body_json(simplifyVector = FALSE)
  
  places = response$places
  
  if (length(places) == 0) {
    return(tibble(
      place_id         = NA_character_,
      google_name      = NA_character_,
      google_address   = NA_character_,
      google_latitude  = NA_real_,
      google_longitude = NA_real_,
      business_status  = NA_character_,
      google_hours     = NA_character_
    ))
  }
  
  map_dfr(places, function(p) {
    hours = pluck(p, "regularOpeningHours", "weekdayDescriptions", .default = character())
    
    tibble(
      place_id         = pluck(p, "id", .default = NA_character_),
      google_name      = pluck(p, "displayName", "text", .default = NA_character_),
      google_address   = pluck(p, "formattedAddress", .default = NA_character_),
      google_latitude  = pluck(p, "location", "latitude", .default = NA_real_),
      google_longitude = pluck(p, "location", "longitude", .default = NA_real_),
      business_status  = pluck(p, "businessStatus", .default = NA_character_),
      google_hours     = if (length(hours) == 0) NA_character_ else paste(hours, collapse = " | ")
    )
  })
}

#--------------------------------------------------
#FALSE avoids another set of API requests if google_candidates exists
#--------------------------------------------------
run_google_search = FALSE

if (run_google_search) {
  google_candidates = coolspaces %>% 
    mutate(google_matches = map2(space_name, Address, search_google)) %>% 
    unnest(google_matches)
}

if (exists("google_candidates")) {
  #check that existing results correspond to this council scrape
  candidate_keys = google_candidates %>% 
    distinct(council_row, space_name, Address) %>% 
    arrange(council_row)
  
  if (!identical(as.character(candidate_keys$space_name),
                 as.character(coolspaces$space_name)) ||
      !identical(as.character(candidate_keys$Address),
                 as.character(coolspaces$Address))) {
    stop("Existing google_candidates do not match the current council rows")
  }
  
  google_candidates_processed = google_candidates %>% 
    mutate(key_distance = stringdist::stringdist(
      Address, google_address, method = "jw", p = 0.1
    )) %>% 
    group_by(council_row) %>% 
    slice_min(order_by = key_distance, n = 1, with_ties = FALSE) %>% 
    ungroup()
  
  coolspace_screen = coolspace_screen %>% 
    left_join(
      google_candidates_processed %>% 
        select(
          council_row, place_id, google_name, google_address,
          google_hours, business_status
        ),
      by = "council_row"
    ) %>% 
    mutate(
      review_required = review_required |
        business_status %in% c("CLOSED_TEMPORARILY", "CLOSED_PERMANENTLY")
    )
  
  stopifnot(nrow(coolspace_screen) == nrow(coolspaces))
}

#==================================================
#inspect candidates
#==================================================
coolspace_screen %>% 
  filter(hours_candidate != "Below hours threshold" | review_required) %>% 
  select(
    space_name, `Opening hours`, hours_candidate, tier1_days, tier2_days,
    weekly_open_hours, weekly_afternoon_hours, weekly_hours_status,
    irregular_schedule, access_question, partial_parse, review_required
  ) %>% 
  arrange(hours_candidate, desc(review_required), space_name)

heat_days = merged_intervals %>% 
  mutate(afternoon_minutes = pmax(0, pmin(close, 17 * 60) - pmax(open, 12 * 60))) %>% 
  group_by(council_row, day) %>% 
  summarise(two_hour_visit = any(afternoon_minutes >= 120)) %>% 
  ungroup() %>% 
  group_by(council_row) %>% 
  summarise(days_with_two_hours = sum(two_hour_visit))

review_list = coolspace_screen %>% 
  left_join(heat_days, by = "council_row") %>% 
  mutate(days_with_two_hours = coalesce(days_with_two_hours, 0L)) %>% 
  filter(days_with_two_hours >= 2) %>% 
  select(
    council_row, space_name, Address, `Opening hours`, hours_candidate,
    days_with_two_hours, weekly_afternoon_hours, weekly_hours_status,
    irregular_schedule, partial_parse, access_question, latitude, longitude
  )

write_csv(review_list, "data/processed/coolspace_review_list.csv")
write_rds(review_list, "data/processed/coolspace_review_list.rds")







