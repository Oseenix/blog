
options(
  blogdown.serve_site.startup = FALSE,
  blogdown.knit.on_save = TRUE,
  blogdown.method = 'markdown'
)


library(blogdown)
library(here)

setwd(here())

blogdown::build_site(build_rmd = TRUE)

