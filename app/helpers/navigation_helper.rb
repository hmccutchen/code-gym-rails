module NavigationHelper
  NavDestination = Data.define(:key, :label, :path)

  NAV_ICONS = {
    today: [ [ :path, { d: "M6.5 6.5v11M17.5 6.5v11M3 9.5v5M21 9.5v5M6.5 12h11" } ] ],
    learn: [ [ :path, { d: "M4 19.5V5.5A2.5 2.5 0 0 1 6.5 3H20v18H6.5A2.5 2.5 0 0 1 4 18.5a2.5 2.5 0 0 1 2.5-2.5H20" } ] ],
    progress: [ [ :path, { d: "M5 20V11M12 20V4M19 20v-6M3 20h18" } ] ],
    history: [ [ :circle, { cx: 12, cy: 12, r: 9 } ], [ :path, { d: "M12 7v5l3 2" } ] ],
    settings: [ [ :path, { d: "M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1" } ],
                [ :circle, { cx: 15, cy: 6, r: 2 } ], [ :circle, { cx: 9, cy: 12, r: 2 } ], [ :circle, { cx: 17, cy: 18, r: 2 } ] ],
    account: [ [ :circle, { cx: 12, cy: 8, r: 4 } ], [ :path, { d: "M4 21a8 8 0 0 1 16 0" } ] ]
  }.freeze

  def nav_destinations
    [
      NavDestination.new(key: :today, label: t("nav.today"), path: root_path),
      NavDestination.new(key: :learn, label: t("learn.title"), path: learn_path),
      NavDestination.new(key: :progress, label: t("progress.title"), path: progress_path),
      NavDestination.new(key: :history, label: t("nav.history"), path: history_path),
      NavDestination.new(key: :settings, label: t("nav.settings"), path: setup_path),
      NavDestination.new(key: :account, label: t("nav.account"), path: account_path)
    ]
  end

  def nav_icon(key)
    shapes = NAV_ICONS.fetch(key).map { |name, attributes| content_tag(name, nil, attributes) }
    tag.svg(safe_join(shapes), viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": 1.8,
            "stroke-linecap": "round", "stroke-linejoin": "round", aria: { hidden: true })
  end

  def nav_current?(path)
    return request.path == path if path == root_path

    request.path == path || request.path.start_with?("#{path}/")
  end
end
