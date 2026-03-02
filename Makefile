# Blog workflow automation
# Usage:
#   make serve          - Knit all .Rmd then start Hugo dev server
#   make knit           - Knit all changed .Rmd files to .md
#   make new TITLE=xxx  - Create new markdown post: content/posts/xxx.md
#   make new-rmd TITLE=xxx SECTION=rmd  - Create new R Markdown post
#   make build          - Knit + Hugo production build
#   make clean          - Remove Hugo generated files

HUGO := $(shell command -v hugo 2>/dev/null || echo "$(HOME)/.local/bin/hugo")
RSCRIPT := Rscript

# Find all .Rmd files and their corresponding .md outputs
RMD_FILES := $(shell find content -name '*.Rmd' 2>/dev/null)
MD_TARGETS := $(RMD_FILES:.Rmd=.md)

.PHONY: serve knit build clean new new-rmd help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

serve: knit ## Knit .Rmd files then start Hugo dev server
	$(HUGO) server -D --bind 0.0.0.0

knit: $(MD_TARGETS) ## Knit all changed .Rmd files to .md
	@echo "All .Rmd files are up to date."

# Pattern rule: knit .Rmd -> .md (only if .Rmd is newer)
%.md: %.Rmd
	@echo "Knitting $< ..."
	$(RSCRIPT) -e "\
		knitr::opts_knit\$$set(base.dir = normalizePath('static/', mustWork = TRUE)); \
		knitr::opts_knit\$$set(base.url = '/'); \
		knitr::opts_chunk\$$set(fig.path = '$(patsubst content/%,%,$(dir $<))$(basename $(notdir $<))_files/figure-html/'); \
		rmarkdown::render('$<', output_format = rmarkdown::md_document(variant = 'gfm', preserve_yaml = TRUE), output_file = '$(notdir $@)')"
	@echo "Done: $@"

build: knit ## Production build (knit + hugo --gc --minify)
	$(HUGO) --gc --minify

clean: ## Remove Hugo generated files
	rm -rf public/ resources/

new: ## Create new post (make new TITLE=my-post SECTION=posts)
ifndef TITLE
	$(error TITLE is required. Usage: make new TITLE=my-post)
endif
	$(HUGO) new $(or $(SECTION),posts)/$(TITLE).md
	@echo "Created: content/$(or $(SECTION),posts)/$(TITLE).md"

new-rmd: ## Create new R Markdown post (make new-rmd TITLE=my-analysis SECTION=rmd)
ifndef TITLE
	$(error TITLE is required. Usage: make new-rmd TITLE=my-analysis)
endif
	@mkdir -p content/$(or $(SECTION),rmd)
	@sed 's/{{ replace .Name "-" " " | title }}/$(shell echo "$(TITLE)" | sed "s/-/ /g")/g; s/{{ .Date }}/$(shell date -Iseconds)/g' \
		archetypes/post.Rmd > content/$(or $(SECTION),rmd)/$(TITLE).Rmd
	@echo "Created: content/$(or $(SECTION),rmd)/$(TITLE).Rmd"
	@echo "Edit it, then run 'make knit' or 'make serve'"
