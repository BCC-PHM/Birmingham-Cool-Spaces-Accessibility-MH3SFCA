# Potential spatial accessibility of indoor cool spaces in Birmingham using a modified Huff three-step floating catchment area (MH3SFCA) method

An application of the modified Huff three-step floating catchment area (MH3SFCA) method to assess the potential spatial accessibility of indoor cool spaces in Birmingham

This analysis was inspired by the published studies on the accessibility of GP and pharmacy applying floating catchment area methods to assess the spatial accessibility of general practitioners (Subal et al., 2021) and community pharmacies (Clark & Newing, 2025).

## Method

Analysis is conducted at **2021 LSOA level across Birmingham**.

1.  **Cool spaces classification**\
    Indoor cool spaces were identified from Birmingham City Council's Warm Welcome spaces directory which can potentially provide cool spaces. Cool spaces are classified into **Tier 1** (open from 10:00 to 17:00 on at least five days a week) and **Tier 2** (open at least two days a week).

2.  **Population (demand)**\
    Demand of cool spaces was represented by mid 2024 LSOA population estimates from ONS

3.  **Walking travel times**\
    Walking travel times between each LSOA population weighted centroid and each cool space (given a walking time of 15 mins threshold) were calculated using a locally hosted OpenStreetMap-based routing engine (OSRM) with a foot profile. Mapbox api was used to evaluate abnormal walking time due to circuity.

4.  **Accessibility index**\
    Potential spatial accessibility was calculated using the modified Huff three-step floating catchment area (MH3SFCA) method which is fully documented in Subal et al. (2021).

Statistics employed:

1.  Modified Huff three-step floating catchment area (MH3SFCA) method

## Data

| Measure | Dataset / source | Year | Role |
|------------------|------------------------------|------------------|------------------|
| Cool space locations and opening hours | Web-scraped from the [Birmingham City Council Warm Welcome spaces directory](https://www.birmingham.gov.uk/directory/73/warm_welcome_spaces_in_birmingham/category/1859) | 2026 | Supply locations; opening hours |
| Spatial boundaries | ONS 2021 LSOA boundaries, Birmingham | 2021 | Spatial unit of analysis |
| Population-weighted centroids | ONS LSOA population-weighted centroids | 2021 | Demand locations (trip origins) |
| Population estimates | ONS LSOA mid-year population estimates | Mid-2024 | Demand size |
| Walking network and travel distances | OpenStreetMap foot network, routed with a locally hosted OSRM server | August 2026 | Walking distance from each LSOA centroid to each cool space |
| Route validation | Mapbox Walking Directions API | 2026 | Re-checks LSOA–site pairs with a circuity ratio above 3 (likely missing network links) |
| Walking speeds | Walking speeds : 1.39 m/s (OSRM default foot speed); 9% heat-day reduction assumed, informed by Obuchi et al. (2021) and evidence on older adults during heatwaves; 0.89 m/s for older adults (Nayak et al.) |  | Convert distances to heat-day walking times for the adult and older-adult scenarios |

## Main code

-   `01_get_coolingspaces` — web-scraping cool spaces from BCC website
-   `02_walking_distance_routing` — calculates travel times using OSRM and Mapbox
-   `03_catchment_area_model` — applies MH3SFCA and plot the result

## Output

-   All plots are in the `figs` folder

## Requirements

The Birmingham cool spaces accessibility analysis was conducted in R. Relevant packages include `tidyverse`, `sf`, `rvest`, `httr2`, `httr`, `jsonlite`, `data.table` and `stringdist`. Walking travel distances were calculated with a locally hosted OSRM routing server running in Docker, using the OpenStreetMap foot profile. A Mapbox access token (Walking Directions API) is needed to re-check flagged routes; it should be stored in `.Renviron`, not in the scripts.

## Disclaimer

Contains OS data © Crown copyright and database right. Source: Office for National Statistics, licensed under the Open Government Licence v3.0. OpenStreetMap data © OpenStreetMap contributors, available under the Open Database Licence. Route validation uses the Mapbox Directions API © Mapbox. Cool space locations and opening hours were sourced from the Birmingham City Council Warm Welcome spaces directory in 2026 and may have changed since.

## Reference

Subal, J., Paal, P., & Krisp, J. M. (2021). Quantifying spatial accessibility of general practitioners by applying a modified huff three-step floating catchment area (MH3SFCA) method. International Journal of Health Geographics, 20(1), 9. <https://doi.org/10.1186/s12942-021-00263-3>

Clark, S. D., & Newing, A. (2025). Assessing spatial accessibility of community pharmacies in England and Wales using floating catchment area techniques. Journal of Pharmaceutical Policy and Practice, 18(1), 2466203. <https://doi.org/10.1080/20523211.2025.2466203>

Obuchi, S. P., Kawai, H., Garbalosa, J. C., Nishida, K., & Murakawa, K. (2021). Walking is regulated by environmental temperature. *Scientific Reports, 11*, 12136. <https://doi.org/10.1038/s41598-021-91633-1>

Lindemann, U., Stotz, A., Beyer, N., Oksa, J., Skelton, D. A., Becker, C., Rapp, K., & Klenk, J. (2017). Effect of indoor temperature on physical performance in older adults during days with normal temperature and heat waves. *International Journal of Environmental Research and Public Health, 14*(2), 186. <https://doi.org/10.3390/ijerph14020186>
