# 6. Placements and the Status widget

Blocked by slice 5.

## Done means

The block appears everywhere Argo CD's does: `{{k8s_status}}`, the "Kubernetes" My page block, the partial
`rubylode_k8s/status`, the welcome page, the default My page, project Overview, pages matching a path list, the top menu
link, and a widget on the Rubylode Status page when that plugin is installed.

## Steps

1. Copy and rename `lib/rubylode_argocd/{macros,hooks,default_my_page_patch}.rb`, `path_matcher.rb`,
   `my/blocks/_rubylode_k8s_status.html.erb`, `_status_plugin_notice.html.erb`, and the partial's `compact` and `widget`
   locals (compact drops the pod detail column).
2. `status_widget.rb` from Argo CD's: `KEY = "k8s"`, `PAGE_PATH = "/status/k8s"`, `PARTIAL = "rubylode_k8s/status"`,
   `.status_plugin_present?`, `.register`, `.data(settings = Settings.current)`, registered from `after_initialize`.
   Plan's call for a cluster's item: `down` when any node is not `Ready`; `warning` when pods are in trouble, pods
   were not checked or metrics are missing; `ok` otherwise; `unknown` when unavailable or without nodes. Argo CD's
   `block_state` unchanged.

## Tests, in order

Port Argo CD's files one case at a time, renaming as you go:

1. `wiki_macro_test.rb`: draws the block, takes a title, uses Block title, nothing for an excluded person, listed among
   the macros, the wiki page answers when every cluster is down.
2. `my_page_block_test.rb`: offered as "Kubernetes" and renders.
3. `placements_test.rb`: each switch on and off, both columns, path matching (never settings or sign-in), no doubled
   block, one cache across placements, the not-set-up hint for administrators only, the top menu link named like Block
   title, the wiki preview carrying the stylesheet.
4. `status_plugin_test.rb`: the notice links to the Status plugin when it is missing; with it, the top menu item goes and
   the partial leaves title and summary to the Status page.
5. `test/unit/status_widget_test.rb`: "a cluster with a NotReady node is down"; "pods in trouble alone make a warning";
   "metrics missing alone make a warning"; "an unavailable cluster is unknown, the block a warning when another is
   fine"; "without clusters the block is unknown and not set up"; "registering passes the key, path and partial".
6. `test/unit/status_partial_without_request_test.rb`: renders with no request and no stylesheet link.

## Not in this slice

The settings form for the placements (7).
