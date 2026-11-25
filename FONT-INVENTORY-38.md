# Font inventory — build 38 (changes 2+3), pre-edit state (branch build38, HEAD 2d51f1b)

## Rules applied
- General: +2pt vs build 37. Explicit `.system(size: N)` → N+2. Semantic styles → `.system(size: default+2, weight: matching)` using: largeTitle 34, title 28, title2 22, title3 20, headline 17 (semibold), body 17, callout 16, subheadline 15, footnote 13, caption 12, caption2 11.
- URL/address text: +4pt total vs build 37 (see URL section).
- tvOS-only (`#if os(tvOS)`) and macOS-only branches are NOT bumped (iOS scope); icon-only SF Symbol `.font` specs on `Image(systemName:)` are not text and are not bumped.
- Settings pages: rows with no explicit font (Toggle/Picker/Button/LabeledContent labels) inherit through `SettingsPage`'s `.dynamicTypeSize(.xLarge)` (SettingsView.swift:175) and the settings hub's `.dynamicTypeSize(.xLarge)` (LocalSettingsView.swift:36) and the home source panel's `.dynamicTypeSize(.xLarge)` (LocalHomeSourcePanel.swift:72). Those containers are bumped one step to `.xxLarge` (= +2 for implicit text) instead of adding a font to every row.

## Settings tree inventory (followed from LocalSettingsView cards/toolbar)
- 首页 → LocalHomeSettingsView (LocalSettingsView.swift) → LocalAppearanceSettingsSection + LocalHTMLHomeSettingsSection (LocalAppearanceDataSettings.swift / LocalHTMLHomeView.swift)
- Dock 按钮 → LocalDockButtonsSettingsView (LocalDockButtons.swift)
- 订阅 / python / 直播 → LocalSourceSettingsView + LocalSourceEditor + ManagedLocalSourceRow (LocalSourceSettingsView.swift; reorder row LocalSettingsReorderRow.swift has no fonts)
- 收藏 → FavoritesView (in LiveView.swift)
- TMDB → TMDBServiceSettingsView.swift
- 在线字幕 → LocalOnlineSubtitleSettingsView (LocalMediaServiceSettings.swift)
- AI字幕 → LocalAISubtitleSettingsView.swift → NativeLocalASRModelSettings (NativeLocalASRModelSettings.swift)
- 播放器 → LocalPlayerSettingsView (LocalPlaybackSettings.swift)
- 视频缓存 → LocalCacheSettingsView (LocalPlaybackSettings.swift) → CacheSettingsView.swift, DownloadsView.swift
- 弹幕 → LocalDanmakuSettingsView (LocalMediaServiceSettings.swift) → LocalDanmakuAPISettings.swift
- 媒体徽章 → LocalMediaBadgeSettingsView.swift
- 去广告 → LocalAdSettingsView (LocalPlaybackSettings.swift)
- 备份迁移 → LocalBackupSettingsView (LocalAppearanceDataSettings.swift)
- 关于 (toolbar) → LocalAboutView (LocalSettingsView.swift) → LicensesView + DiagnosticsView (SettingsView.swift), LocalDataSettingsView (LocalSettingsView.swift)
- Shared settings building blocks: SettingsPage/SettingsGroup/SettingsRow/SettingsLinkRow/SettingsActionRow/FormLabel/FormLink/SettingsWebRow/SettingsIcon (SettingsView.swift lines 1–409)
- Also listed for the tree: EpisodeSkipSettingsView.swift, SubtitleStyleView.swift, LocalSearchSettingsView.swift (search settings, pushed from GlobalSearchView)
- Checked and NOT in the iOS local settings tree: MoreView.swift (tab-bar/More page, no About there — About is LocalAboutView in LocalSettingsView.swift), SettingsView.swift's FormSettingsView/PlaybackSettingsView/PrivacySettingsView/TVSettings* (macOS/tvOS roots, not routed from LocalSettingsView; only the shared blocks + Licenses/Diagnostics above are), NativeLocalASRModelSettings is included via AI字幕.

## URL / address elements (+4 total) — marked [URL]
- LocalSourceSettingsView.swift:344 (line no. pre-edit ~319 in font dump; row caption) — `Text(caption).font(captionIsURL ? .system(.caption2, design: .monospaced) : .caption2)`: URL branch caption2 11 monospaced → 15 monospaced [URL]; non-URL branch caption2 11 → 13 (general +2)
- LocalSourceSettingsView.swift — subscription/live/python entry rows use the caption above for every entry URL (订阅 rows + 直播 rows) [URL]
- LocalSourceSettingsView.swift — address TextField in the add-source form ("订阅 / M3U / Python 地址", implicit body 17) → explicit 21 [URL]; LocalSourceEditor address TextField (implicit 17) → explicit 21 [URL]
- LocalDanmakuAPISettings.swift:24 — `Text(api.url).font(.caption)` 12 → 16 [URL]; the API-address TextField in the editor (implicit 17) → explicit 21 [URL]
- LocalMediaBadgeSettingsView.swift:32 — `Text(source.address).font(.caption)` 12 → 16 [URL] (badge source address)
- TMDBServiceSettingsView.swift — "API 地址" / "图片地址" / "代理地址" TextFields (implicit 17, prompt shows the default URL) → explicit 21 [URL]
- SettingsView.swift (LicensesView) — `Link("www.getmegaportal.com").font(.subheadline)` 15 → 19 [URL]
- LocalSettingsView.swift — no row displays a URL (About rows show version/build only). LocalSearchSettingsView / other settings pages: no URL text found.

## Computed / variable sizes (base constants bumped, noted)
- HomeView.swift:229 hero title: `.system(size: heroTitle)` — heroTitle = 52 (iOS regular) / Layout.heroTitle; bumped HomeView 52→54 and GlassKit.swift Layout.heroTitle iOS branch 34→36 (tvOS 68 / macOS 48 branches untouched). AppMark/frames scale off the same value.
- DiscoverLayout (DiscoverTVLayout.swift, non-tvOS branch): heading 16→18, caption 13→15, secondary 11→13; captionHeight 46→50, headingHeight 32→34 so the larger captions are not clipped. Used by DiscoverView, DiscoveryView (Recommendations), DiscoverCalendarView, WatchNowPhone (home) — and MangaView (spillover, see report).
- SitesView.swift:765/768 SourceOrderRow font vars: tvOS branch (29/22) untouched; iOS branch `Font.body.weight(.medium)` → 19 medium, `Font.caption` → 14.
- LiveRoomsView.swift:397/401 platform font vars: tvOS (30/22) untouched; iOS `Font.subheadline.weight(.semibold)` → 17 semibold, `Font.caption2` → 13.
- Scaled-expression glyph sizes NOT bumped (icon/monogram artwork, size derives from a tile-size parameter, not a font spec): SitesView MonogramIcon `size * 0.5` / `size * 0.44`, SourceRankBadge `size * 0.62`, LiveView ChannelLogo `size * 0.55` / `size * 0.4`, LiveRoomsView glyph `size * 0.52`, HomeView PosterWall `width * 0.26`, SitesView PluginNodeView `(node.size ?? 15) * scale` (data-driven plugin UI), DownloadsView `DownloadMetrics.thumb`-ternary icon sizes.
- DiscoveryView.swift:2077 SourceChip `.system(size: overlayArrows ? 14 : 11)` — ternary base values bumped 14→16 / 11→13.

## Excluded (not touched)
- VideoDetailView (SitesView.swift line 2384→end), CatalogDetailSections.swift, LocalCatalogPresentation.swift, LocalCatalogEpisodes.swift, DiscoverDetailView.swift, DiscoverDetailPanels.swift, CatalogPlaybackActions.swift
- Player: PlayerView.swift, PlaybackView.swift, MobilePlayer.swift and player panels
- Music*.swift (no shared font helper needed changing — see report), Manga views (except DiscoverLayout constant spillover), Cloud files views, DiscoverArtwork.swift (change 1, already committed)

## Per-file elements (pre-edit specs; line numbers pre-edit)


### App/HomeView.swift — 6 font spec(s)
- 225: Text(L10n.text("Yingxia")).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
- 229: .font(.system(size: heroTitle, weight: .bold, design: .rounded))
- 233: .font(.title3).foregroundStyle(.secondary)
- 521: Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
- 522: Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 582: .font(.system(size: width * 0.26, weight: .semibold))

### App/WatchNowPhone.swift — 11 font spec(s)
- 273: Text(L10n.text("Up Next")).font(.system(size: 13, weight: .semibold)).opacity(0.7)
- 279: Text(entry.context.videoName).font(.system(size: 34, weight: .bold))
- 286: .font(.system(size: 14)).lineLimit(1).padding(.top, 14)
- 291: Text(HistoryFormat.status(entry)).font(.system(size: 12).monospacedDigit()).opacity(0.75)
- 297: .font(.system(size: 16, weight: .semibold))
- 334: Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassSurface(.regular, in: Circle())
- 371: Text(title).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
- 374: Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold))
- 444: Text(title).font(.system(size: DiscoverLayout.caption)).lineLimit(1)
- 445: Text(detail.isEmpty ? " " : detail).font(.system(size: DiscoverLayout.secondary, design: .rounded))
- 509: Image(systemName: cloud.symbol).font(.system(size: 40, weight: .medium)).foregroundStyle(cloud.tint)

### App/LocalHomeSourcePanel.swift — 9 font spec(s)
- 72: .dynamicTypeSize(.xLarge)
- 98: Text(option.title).font(.subheadline.weight(.semibold)).lineLimit(1)
- 138: .font(.subheadline.weight(.semibold)).lineLimit(2)
- 139: Image(systemName: "chevron.down").font(.caption.weight(.semibold))
- 168: .buttonStyle(.plain).font(.system(size: 17, weight: .medium))
- 200: .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 12)
- 202: Text("没有匹配的 HTML 首页").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 12)
- 204: if !htmlFailure.isEmpty { Text(htmlFailure).font(.footnote).foregroundStyle(.secondary) }
- 215: Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)

### App/LocalHTMLHomeView.swift — 4 font spec(s)
- 42: .font(.system(size: 13, weight: .medium))
- 287: @Environment(\.dynamicTypeSize) private var dynamicType
- 301: if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
- 342: Text(source.name).font(.subheadline.weight(.medium)).lineLimit(1)

### App/SitesView.swift — 49 font spec(s) (scope lines [(1, 2383)])
- 223: Text("首页").font(.headline).frame(maxWidth: .infinity, minHeight: 64)
- 318: Text(L10n.text(group.title)).font(.headline).lineLimit(1)
- 319: Text("\(group.sites.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
- 322: Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
- 442: Image(systemName: "circle.fill").font(.system(size: size)).foregroundStyle(tint).accessibilityLabel(status.summary)
- 482: Image(systemName: "pin.fill").font(.system(size: icon * 0.18, weight: .bold)).foregroundStyle(Brand.onAccent)
- 492: Text(label.parts[0]).font(.headline).lineLimit(1)
- 497: .font(.caption).foregroundStyle(.secondary)
- 499: if dimmed { Text(L10n.text("Hidden")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
- 502: Text(detail).font(.subheadline).lineLimit(1)
- 508: Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(focused ? Color.black : Brand.accent)
- 512: if chosen == nil { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
- 577: // Sized by frame rather than font: font-sized symbols sit off-center (baseline/ascent padding) before macOS 26.
- 581: Text(symbol).font(.system(size: size * 0.5))
- 583: Text(String(label.parts[0].prefix(1)).uppercased()).font(.system(size: size * 0.44, weight: .bold, design: .rounded)).foregroundStyle(.white)
- 673: Text(L10n.text("Custom Search Order")).font(.headline)
- 674: Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 692: .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.onAccent)
- 733: Text(verbatim: "+\(sites.count - shown.count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
- 748: Text(rank, format: .number).font(.system(size: size * 0.62, weight: .bold, design: .rounded)).monospacedDigit()
- 765: private let title = Font.system(size: 29, weight: .medium), caption = Font.system(size: 22)
- 768: private let title = Font.body.weight(.medium), caption = Font.caption
- 775: Text(rank, format: .number).font(caption.weight(.semibold)).monospacedDigit()
- 781: Text(label.parts[0]).font(title).lineLimit(1)
- 784: if !detail.isEmpty { Text(detail).font(caption).foregroundStyle(.secondary).lineLimit(1) }
- 831: .font(.system(size: 24)).foregroundStyle(.secondary).padding(.bottom, 12)
- 953: Text(L10n.text("Hide or Show Sources")).font(.headline).foregroundStyle(.primary)
- 954: Text(L10n.text("Choose many sources at once, or a whole subscription.")).font(.subheadline).foregroundStyle(.secondary)
- 958: if !value.isEmpty { Text(value).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1) }
- 959: Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
- 998: .font(.system(size: 24)).foregroundStyle(.secondary).padding(.bottom, 12)
- 1006: Text(L10n.text(group.title)).font(.system(size: 31, weight: .semibold)).lineLimit(1)
- 1019: Image(systemName: shown ? "checkmark.circle.fill" : "circle").font(.system(size: 30))
- 1047: .font(.subheadline).foregroundStyle(.secondary)
- 1124: Image(systemName: shown ? "checkmark.circle.fill" : "circle").font(.title3)
- 1127: Text(label.parts[0]).font(.body.weight(.medium)).lineLimit(1)
- 1130: if !shown { Text(L10n.text("Hidden")).font(.caption).foregroundStyle(.secondary) }
- 1322: .font(.headline).buttonStyle(.plain)
- 1345: Text(folder?.name ?? SourceLabel(site.name).text).font(.headline).lineLimit(2)
- 1346: Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
- 1365: Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
- 1370: .font(.subheadline).submitLabel(.search)
- 1446: Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
- 1609: Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
- 1693: Label(L10n.text("Reset Filters"), systemImage: "xmark").font(.system(size: 13)).padding(.horizontal, 12).frame(height: 30)
- 1844: .font(.callout)
- 2042: if let title = window.title { Text(title).font(.headline) }
- 2043: if let message = window.message { Text(message).font(.body).fixedSize(horizontal: false, vertical: true) }
- 2223: .font(.system(size: (node.size ?? 15) * scale, weight: node.bold ? .semibold : .regular))

### App/DiscoverView.swift — 50 font spec(s)
- 213: .font(.subheadline).frame(maxWidth: .infinity).padding()
- 231: .font(.subheadline).padding(18).glassSurface(.regular, in: Capsule())
- 244: .font(.caption2).foregroundStyle(.white.opacity(0.5))
- 293: Image(systemName: "text.magnifyingglass").font(.system(size: 28))
- 450: Text(kind.shelfTitle).font(.system(size: DiscoverLayout.heading, weight: .semibold))
- 452: Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold))
- 487: Text(title).font(.system(size: DiscoverLayout.heading, weight: .semibold))
- 489: Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold))
- 499: Text(title).font(.system(size: DiscoverLayout.heading, weight: .semibold))
- 523: Text(person.name).font(.system(size: 26, weight: .medium)).lineLimit(1).cardCaption()
- 547: Text(person.name).font(.system(size: DiscoverLayout.caption)).lineLimit(1)
- 637: Text(feed.title).font(.system(size: 19, weight: .semibold))
- 757: Text(feed.title).font(.system(size: DiscoverLayout.heading, weight: .semibold))
- 759: Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold))
- 1071: Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassSurface(.regular, in: Circle())
- 1302: Text(item.name).font(.system(size: 40, weight: .semibold))
- 1303: .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
- 1310: .font(.system(size: 14)).lineLimit(1).frame(height: 17)
- 1312: .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
- 1317: Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 11))
- 1344: Text(item.name).font(.system(size: DiscoverLayout.caption)).lineLimit(1)
- 1351: }.font(.system(size: DiscoverLayout.secondary, design: .rounded)).foregroundStyle(.primary.opacity(0.56))
- 1376: Image(systemName: "laurel.leading").font(.system(size: 38))
- 1378: Text(feed.collectionTitle).font(.system(size: 34, weight: .semibold))
- 1379: Text(items.first?.name ?? "").font(.system(size: 14)).opacity(0.8)
- 1381: Image(systemName: "laurel.trailing").font(.system(size: 38))
- 1468: Image(systemName: "laurel.leading").font(.system(size: 52)).frame(width: 64, height: 64)
- 1470: Text(feed.collectionTitle).font(.system(size: 64, weight: .semibold))
- 1471: Text(items.first?.name ?? "").font(.system(size: 29, weight: .medium)).opacity(0.75)
- 1472: }.lineLimit(1).minimumScaleFactor(0.7)
- 1473: Image(systemName: "laurel.trailing").font(.system(size: 52)).frame(width: 64, height: 64)
- 1494: Text(item.name).font(.system(size: 29))
- 1499: }.font(.system(size: 23, weight: .medium)).foregroundStyle(.white.opacity(0.5))
- 1521: .font(.system(size: 29, weight: .medium))
- 1548: Text(title).font(.system(size: 52, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
- 1583: Text(item.name).font(.system(size: 29))
- 1584: Text(caption.isEmpty ? " " : caption).font(.system(size: 23, weight: .medium)).foregroundStyle(.white.opacity(0.5))
- 1613: else { Text(brand.name).font(.system(size: 32, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6) }
- 1695: Text(title).font(.system(size: 30, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
- 1728: Text(title).font(.system(size: 40, weight: .bold)).frame(maxHeight: .infinity)
- 1762: else { Text(brand.name).font(.system(size: 24, weight: .semibold)) }
- 1799: Text(feed.title).font(.system(size: 31, weight: .semibold)).padding(.bottom, 28)
- 2034: Text(item.title).font(.system(size: DiscoverLayout.caption))
- 2035: Text(item.caption.isEmpty ? " " : item.caption).font(.system(size: DiscoverLayout.secondary, weight: .medium)).foregroundStyle(.white.opacity(0.5))
- 2045: Text(item.title).font(.system(size: DiscoverLayout.caption)).lineLimit(1)
- 2047: .font(.system(size: DiscoverLayout.secondary, design: .rounded)).foregroundStyle(.primary.opacity(0.56))
- 2072: Text(feed.title).font(.system(size: 52, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
- 2171: Text(item.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
- 2172: if !item.caption.isEmpty { Text(item.caption).font(.headline).opacity(0.7) }
- 2173: if !item.subtitle.isEmpty { Text(item.subtitle).font(.subheadline).opacity(0.6).multilineTextAlignment(.center) }

### App/DiscoverBrowseView.swift — 3 font spec(s)
- 194: Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
- 195: Text(item.date ?? item.year.map(String.init) ?? "—").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
- 211: Image(systemName: "line.3.horizontal.decrease").font(.system(size: 20)).frame(width: 48, height: 48).glassSurface(.regular, in: Circle())

### App/DiscoverHomeSearchView.swift — 13 font spec(s)
- 63: Text("最近搜索").font(.headline); Spacer()
- 64: Button("全部清除") { model.clearHistory() }.font(.subheadline).frame(minHeight: 44)
- 71: Button { model.removeHistory(title) } label: { Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44) }
- 73: }.font(.subheadline).buttonStyle(.plain).background(.primary.opacity(0.06), in: Capsule())
- 80: Text("热门搜索").font(.headline)
- 84: Label(item.name, systemImage: "magnifyingglass").font(.subheadline)
- 92: Text("输入片名，搜索首页电影和剧集资料。").font(.subheadline).foregroundStyle(.secondary).padding(.top, 16)
- 99: Text("搜索联想").font(.headline)
- 104: .font(.subheadline).frame(minHeight: 48).contentShape(Rectangle())
- 108: Text("点击搜索，查找「\(keyword)」").font(.subheadline).foregroundStyle(.secondary)
- 116: Text("「\(model.submittedQuery)」").font(.headline)
- 118: if !model.loading { Text("\(model.items.count) 个结果").font(.caption).foregroundStyle(.secondary) }
- 122: Text(error).font(.subheadline).foregroundStyle(.secondary)

### App/DiscoverCalendarView.swift — 17 font spec(s)
- 58: Text(L10n.text("Airing Schedule")).font(.system(size: 52, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
- 213: Text(title).font(.subheadline.weight(selected ? .semibold : .medium))
- 238: .font(.footnote).foregroundStyle(.secondary)
- 329: Text(item.title).font(.system(size: DiscoverLayout.caption))
- 330: Text(DiscoverAiring.caption(item)).font(.system(size: DiscoverLayout.secondary, weight: .medium))
- 342: Text(item.title).font(.system(size: DiscoverLayout.caption)).lineLimit(1)
- 344: .font(.system(size: DiscoverLayout.secondary, design: .rounded)).monospacedDigit()
- 357: .font(.system(size: 20, weight: .bold)).padding(.horizontal, 12).padding(.vertical, 5)
- 359: .font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
- 440: Text(item.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
- 441: if item.originalTitle != item.title { Text(item.originalTitle).font(.headline).opacity(0.7) }
- 442: Text(DiscoverAiring.caption(item)).font(.subheadline).opacity(0.6)
- 466: .font(.system(size: 15, weight: .semibold)).frame(width: 260).frame(height: 50)
- 489: Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
- 497: Text(title).font(.system(size: 15)).lineLimit(1)
- 529: .font(.system(size: 22))
- 531: .font(.caption2)

### App/PlaybackHistoryView.swift — 13 font spec(s)
- 71: HStack { Text("观看 · \(entries.count) 条").font(.title3.bold()); Spacer(); actions }
- 72: VStack(alignment: .leading, spacing: 10) { Text("观看 · \(entries.count) 条").font(.title3.bold()); HStack { actions } }
- 75: .font(.subheadline).foregroundStyle(.secondary)
- 77: .font(.footnote).foregroundStyle(.secondary)
- 103: Text(entry.context.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(2)
- 105: .font(.caption).foregroundStyle(.secondary).lineLimit(2)
- 106: Text(HistoryFormat.status(entry)).font(.caption).foregroundStyle(.secondary)
- 108: Text(entry.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
- 120: }.font(.subheadline).buttonStyle(.borderless)
- 261: Text(entry.context.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
- 265: .font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
- 266: Text(HistoryFormat.status(entry)).font(.caption).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
- 270: Text(episodeLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()

### App/LiveView.swift — 25 font spec(s)
- 101: Text(label.parts[0]).font(.headline).lineLimit(1)
- 104: Text(detail).font(.subheadline).lineLimit(1)
- 110: Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
- 212: Text(L10n.text("Channels: %lld", filtered.count)).font(.caption).foregroundStyle(.secondary)
- 254: Text(source.name).font(.system(size: 28, weight: .semibold)).lineLimit(1)
- 272: .font(.system(size: 21, weight: .semibold)).foregroundStyle(.secondary)
- 273: Text(channel.name).font(.system(size: 52, weight: .bold)).lineLimit(2)
- 277: }.font(.system(size: 24)).foregroundStyle(.secondary)
- 317: }.font(.system(size: 20)).foregroundStyle(.secondary)
- 386: Text(channel.name).font(.system(size: 28, weight: .semibold)).lineLimit(1)
- 388: Text(channel.displayGroup).font(.system(size: 22)).opacity(0.65).lineLimit(1)
- 389: if store.isFavorite(channel) { Image(systemName: "heart.fill").font(.system(size: 20)) }
- 390: Image(systemName: "play.fill").font(.system(size: 20)).frame(width: 44)
- 412: Text(String(channel.name.prefix(1))).font(.system(size: size * 0.55, weight: .bold))
- 456: configuration.label.font(.system(size: 23, weight: .semibold))
- 477: Text("收藏 · \(store.favorites.titleVideos.count) 部").font(.title3.bold())
- 482: Text("喜欢的故事，随时回来看看。").font(.subheadline).foregroundStyle(.secondary)
- 566: Text(video.videoName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
- 605: Text(episode.video.videoName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
- 607: Text(episode.episodeName).font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
- 632: Image(systemName: "info").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).artworkBadge()
- 687: .font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(.white)
- 717: Text(channel.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
- 718: Text(channel.displayGroup).font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 725: .font(.title3).foregroundStyle(favorite ? Brand.rose : .secondary)

### App/LiveRoomsView.swift — 16 font spec(s)
- 275: Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
- 285: Text(failure).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
- 309: Image(systemName: "dot.radiowaves.left.and.right").font(.caption2.weight(.bold))
- 310: Text(L10n.text("LIVE")).font(.caption2.weight(.bold))
- 320: .font(.caption2.weight(.semibold)).foregroundStyle(.white).labelStyle(.titleAndIcon)
- 329: Image(systemName: "heart.fill").font(.caption).foregroundStyle(Brand.rose)
- 334: Text(room.title.isEmpty ? room.host : room.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
- 336: Text([room.host, room.area].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 397: private let titleFont = Font.system(size: 30, weight: .bold), detailFont = Font.system(size: 22, weight: .medium)
- 401: private let titleFont = Font.subheadline.weight(.semibold), detailFont = Font.caption2
- 457: Text(platform.name).font(titleFont).lineLimit(1)
- 470: .font(detailFont).foregroundStyle(.white.opacity(0.8))
- 479: .font(.caption2.weight(.bold)).foregroundStyle(.white)
- 504: return Text(glyph).font(.system(size: size * 0.52, weight: .heavy, design: .rounded)).foregroundStyle(.white)
- 505: .background { WithPerceptionTracking { Text(glyph).font(.system(size: size * 0.52, weight: .heavy, design: .rounded)).foregroundStyle(Color(red: 0.15, green: 0.96, blue: 0.94)).offset(x: -offset, y: -offset).opacity(spli
- 506: .background { WithPerceptionTracking { Text(glyph).font(.system(size: size * 0.52, weight: .heavy, design: .rounded)).foregroundStyle(Color(red: 1.0, green: 0.17, blue: 0.33)).offset(x: offset, y: offset).opacity(split ?

### App/DiscoveryView.swift — 58 font spec(s)
- 47: .font(.footnote).foregroundStyle(.secondary)
- 66: .font(.subheadline.weight(selected ? .semibold : .regular))
- 88: Text(count, format: .number).font(.caption.weight(.medium)).monospacedDigit()
- 244: .font(.system(size: 19, weight: .semibold))
- 349: Text(L10n.text("Search all available sources in your subscription.")).font(.body).foregroundStyle(.secondary)
- 392: .font(.subheadline.weight(.semibold)).lineLimit(1)
- 419: .font(.subheadline).foregroundStyle(.secondary)
- 440: Text("等待站点返回结果…").font(.subheadline).foregroundStyle(.secondary)
- 447: Text(L10n.text("Searching for “%@”…", model.keyword)).font(.title3.weight(.semibold))
- 461: Text("部分来源下一页加载失败，可重试。").font(.footnote).foregroundStyle(.secondary)
- 590: .font(.headline).lineLimit(1).truncationMode(.tail)
- 684: Text("\(model.completed) / \(model.total)").font(.subheadline.weight(.semibold)).fixedSize()
- 685: Text(summaryDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 697: Text(L10n.text("%lld results", model.videoCount)).font(.headline)
- 699: .font(.subheadline).foregroundStyle(.secondary)
- 754: Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
- 762: .font(.system(size: 9, weight: .bold)).monospacedDigit()
- 793: .font(.footnote.weight(.semibold))
- 805: Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
- 870: Text(video.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
- 873: Text(video.remarks).font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 876: Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
- 879: Text(SourceLabel(item.site.name).text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 895: .font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 901: Text(SourceLabel(item.site.name).text).font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
- 909: Text(L10n.text("Search all available sources in your subscription.")).font(.body).foregroundStyle(.secondary)
- 912: Text(L10n.text("Recent Searches")).font(.headline)
- 920: Image(systemName: "magnifyingglass").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
- 921: Text(L10n.text("Search all available sources in your subscription.")).font(.title3.weight(.medium)).multilineTextAlignment(.center)
- 925: Text(L10n.text("Recent Searches")).font(.title3.weight(.bold))
- 927: Button(L10n.text("Clear")) { historyData = Data() }.buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(minHeight: 44)
- 935: Image(systemName: "clock.arrow.circlepath").font(.body).foregroundStyle(.secondary).frame(width: 24)
- 936: Text(item).font(.body).lineLimit(1)
- 943: Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
- 950: Image(systemName: "arrow.up.left").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
- 989: HStack(spacing: 6) { Text(result.site.name).font(.headline); SourceHealthDot(status: health) }
- 990: Text(result.error ?? "").font(.caption).foregroundStyle(.secondary)
- 991: if health == .failing { Text(health.summary).font(.caption).foregroundStyle(Brand.rose) }
- 999: HStack(spacing: 6) { Text(site.name).font(.headline); SourceHealthDot(status: .failing) }
- 1000: Text(pauseNote(site)).font(.caption).foregroundStyle(Brand.rose)
- 1146: .font(.subheadline)
- 1183: Text(title).font(.system(size: 31, weight: .medium)).lineLimit(1).fixedSize()
- 1235: .font(.system(size: 12, weight: .semibold))
- 1379: .font(.system(size: 15, weight: .medium))
- 1409: Image(systemName: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
- 1427: Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
- 1429: .font(.subheadline.weight(.semibold))
- 1491: Text(L10n.text("Recommendations")).font(.title3.weight(.bold))
- 1519: Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
- 1596: Text(L10n.text("Recommendations")).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
- 1668: Text(L10n.text("Recommendations")).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
- 1685: Text(error).font(.subheadline).foregroundStyle(.secondary)
- 1710: .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, DiscoverLayout.gutter)
- 1766: Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
- 1796: Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
- 2077: .font(.system(size: overlayArrows ? 14 : 11, weight: .bold))
- 2112: if let dot { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(dot) }
- 2114: .font(.system(size: 13, weight: selected ? .semibold : .medium))

### App/DiscoverSearchView.swift — 17 font spec(s) (scope lines [(1, 437)])
- 89: Text(L10n.text("Search")).font(.system(size: 17, weight: .semibold)).frame(height: 44).frame(maxWidth: .infinity)
- 135: Button { dismiss() } label: { Image(systemName: "safari.fill").font(.system(size: 26)).frame(width: 48, height: 48).glassSurface(.regular, in: Circle()) }
- 148: } label: { WithPerceptionTracking { Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 23)).foregroundStyle(.secondary) } }
- 150: } else { Image(systemName: "magnifyingglass").font(.system(size: 19)).foregroundStyle(.secondary) }
- 161: } label: { Image(systemName: "xmark").font(.system(size: 23)).frame(width: 48, height: 48).glassSurface(.regular, in: Circle()) }
- 169: Text(L10n.text("Recent Searches")).font(.system(size: 16, weight: .semibold)); Spacer()
- 170: Button { model.clearHistory() } label: { Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(.secondary) }
- 178: Button { query = text; focused = false } label: { Text(text).font(.system(size: 13)).padding(.horizontal, 14).frame(height: 34).glassSurface(.regular, in: Capsule()).iosTouchTarget() }
- 237: Text(filter == nil ? kind.title : L10n.text("Filtered Results")).font(.system(size: 16, weight: .semibold))
- 240: .font(.system(size: 15, weight: .medium))
- 262: Text(item.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
- 264: .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
- 271: .font(.system(size: 11)).frame(width: 12).foregroundStyle(rating / 2 > Double(index) ? Color.yellow : .secondary)
- 275: Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 13)).foregroundStyle(.yellow)
- 278: Text(item.overview.isEmpty ? " " : item.overview).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(2)
- 293: Text(person.name).font(.system(size: 13)).lineLimit(1).padding(.top, 8)
- 295: .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)

### App/LocalSettingsView.swift — 5 font spec(s)
- 7: @Environment(\.dynamicTypeSize) private var dynamicType
- 36: .dynamicTypeSize(.xLarge)
- 57: Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
- 59: Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
- 115: .font(.footnote).foregroundStyle(.secondary)

### App/LocalSourceSettingsView.swift — 9 font spec(s)
- 137: .font(.caption).foregroundStyle(.secondary)
- 144: Text(report.details).font(.caption).foregroundStyle(.secondary)
- 319: .font(captionIsURL ? .system(.caption2, design: .monospaced) : .caption2)
- 325: Text(failure).font(.footnote).foregroundStyle(.red)
- 385: Text("名称").font(.caption).foregroundStyle(.secondary)
- 394: Text("地址").font(.caption).foregroundStyle(.secondary)
- 406: Text("来源").font(.caption).foregroundStyle(.secondary)
- 407: Text(originLabel).font(.callout).lineLimit(2).truncationMode(.middle)
- 418: if let error { Text(error).font(.footnote).foregroundStyle(.red) }

### App/LocalDanmakuAPISettings.swift — 3 font spec(s)
- 24: Text(api.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
- 42: if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
- 44: .font(.caption).foregroundStyle(.secondary)

### App/LocalPlaybackSettings.swift — 1 font spec(s)
- 22: if let cacheStatus { Text(cacheStatus).font(.footnote).foregroundStyle(.secondary) }

### App/LocalAppearanceDataSettings.swift — 2 font spec(s)
- 71: if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
- 75: if let createdAt { Text(createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption) }

### App/CacheSettingsView.swift — 0 font spec(s)

### App/LocalSearchSettingsView.swift — 1 font spec(s)
- 66: .font(.footnote).foregroundStyle(.secondary)

### App/LocalMediaBadgeSettingsView.swift — 6 font spec(s)
- 18: if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
- 23: Text(source.name).font(.headline)
- 24: Text("\(source.rules?.rules.count ?? 0) 枚徽章").font(.caption).foregroundStyle(.secondary)
- 32: if !source.address.isEmpty { Text(source.address).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
- 55: Text(badge.name).font(.caption).lineLimit(2)
- 96: else { Text(badge.name).font(.caption2).padding(.horizontal, 5).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4)) }

### App/LocalAISubtitleSettingsView.swift — 12 font spec(s)
- 21: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 29: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 31: Text("离线语言包").font(.subheadline.weight(.semibold))
- 37: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 44: Text("有尚未保存的设置").font(.caption).foregroundStyle(.secondary)
- 51: Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 84: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 88: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 96: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 103: Text(title).font(.subheadline).foregroundStyle(.secondary)
- 111: Text(title).font(.subheadline).foregroundStyle(.secondary)
- 115: Button("清除密钥") { text.wrappedValue = ""; status = "清除后请保存设置" }.font(.caption)

### App/NativeLocalASRModelSettings.swift — 21 font spec(s)
- 19: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 20: if let error = models.catalogError { Text(error).font(.caption).foregroundStyle(.red) }
- 22: Text("请选择音频对应的语言。").font(.caption).foregroundStyle(.secondary)
- 40: Text(model.name).font(.headline)
- 42: Text("\(model.files.count) 个文件 · \(bytes(model.bytes))").font(.caption).foregroundStyle(.secondary)
- 45: Text(model.name).font(.headline)
- 46: Text("\(model.files.count) 个文件 · \(bytes(model.bytes))").font(.caption).foregroundStyle(.secondary)
- 51: Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 63: Label("尚未下载", systemImage: "arrow.down.circle").font(.subheadline).foregroundStyle(.secondary)
- 70: Text(fileDescription(model, completed: received)).font(.caption).foregroundStyle(.secondary)
- 74: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 81: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 86: .font(.caption).foregroundStyle(.secondary)
- 89: Label("文件完整，尚未检查加载", systemImage: "checkmark.circle").font(.subheadline)
- 91: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 97: .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 106: Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
- 110: Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
- 117: Text(title).font(.subheadline.weight(.medium))
- 121: .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
- 122: } else { ProgressView(); Text("正在等待文件大小…").font(.caption).foregroundStyle(.secondary) }

### App/TMDBServiceSettingsView.swift — 2 font spec(s)
- 41: .font(.caption).foregroundStyle(.secondary)
- 46: if let message { SettingsGroup { Text(message).font(.footnote).foregroundStyle(.secondary) } }

### App/EpisodeSkipSettingsView.swift — 5 font spec(s)
- 35: .font(.footnote).foregroundStyle(.secondary)
- 40: .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("player.skip.remoteStatus")
- 44: .font(.footnote)
- 72: .font(.footnote).foregroundStyle(.secondary)
- 75: .font(.footnote).foregroundStyle(.secondary)

### App/SubtitleStyleView.swift — 5 font spec(s)
- 90: let families = Set(UIFont.familyNames)
- 358: .font(.body.weight(.semibold))
- 412: Text(L10n.text("Subtitle Style")).font(.system(size: 44, weight: .bold))
- 488: .font(.system(size: 26, weight: .medium))
- 526: if style.font == family { Image(systemName: "checkmark").font(.system(size: 26, weight: .semibold)) }

### App/SettingsView.swift — 32 font spec(s) (scope lines [(1, 409), (1257, 1680)])
- 28: Text(title).font(.headline).foregroundStyle(.secondary)
- 32: .font(.subheadline).frame(minHeight: 44)
- 42: if let footer { Text(footer).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
- 71: Text(title).font(.system(size: 29, weight: .medium)).lineLimit(2)
- 73: Text(subtitle).font(.system(size: 23)).foregroundStyle(.secondary).lineLimit(3)
- 175: .dynamicTypeSize(.xLarge)
- 251: .font(.system(size: FormMetrics.symbol, weight: .semibold)).foregroundStyle(.white)
- 271: if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
- 326: Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
- 1271: Text(paragraph.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 24)).foregroundStyle(.secondary)
- 1283: Text("Yingxia \(Brand.copyright)").font(.headline)
- 1284: Link("www.getmegaportal.com", destination: Brand.website).font(.subheadline)
- 1289: .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).selectable()
- 1344: Image(systemName: live ? "circle.fill" : "pause.circle.fill").font(.system(size: live ? 6 : 11)).foregroundStyle(live ? Brand.accent : .secondary)
- 1349: .font(.caption).foregroundStyle(.secondary).padding(.horizontal, DiagnosticGrid.inset).padding(.vertical, 12)
- 1355: .font(.caption).foregroundStyle(.secondary)
- 1358: .font(.caption).foregroundStyle(Brand.amber)
- 1360: if let error { Text(error).font(.caption).foregroundStyle(Brand.rose).selectable() }
- 1379: Text(L10n.text("Runtime Activity")).font(.title2.weight(.bold))
- 1381: Text(L10n.text("Inspect plugin requests and errors.")).font(.subheadline).foregroundStyle(.secondary)
- 1459: .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
- 1484: .font(.caption.weight(.medium)).foregroundStyle(.secondary)
- 1584: }.font(.caption).foregroundStyle(.secondary)
- 1585: Text(entry.message).font(.body).lineLimit(2).multilineTextAlignment(.leading)
- 1605: Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
- 1623: .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
- 1627: Text(entry.level.rawValue.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced))
- 1632: Text(entry.category).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
- 1638: return Text(preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary.opacity(0.88))
- 1651: Text(entry.category).font(.headline)
- 1655: Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
- 1658: Text(entry.message).font(.system(.body, design: .monospaced)).selectable()

### App/LocalDockButtons.swift — 3 font spec(s)
- 116: .font(.system(size: 19, weight: .semibold))
- 118: Text(button.title).font(.body.weight(.medium)).lineLimit(1)
- 121: Text("常驻").font(.caption).foregroundStyle(.secondary)

### App/LocalMediaServiceSettings.swift — 1 font spec(s)
- 61: if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }

### App/DownloadsView.swift — 37 font spec(s)
- 116: Text(L10n.text("Downloading")).font(.title3.weight(.semibold))
- 117: Text("\(pending.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
- 139: .font(.subheadline)
- 159: Text("\(pending.count)").font(.headline).monospacedDigit().foregroundStyle(.secondary)
- 331: Text(L10n.text("Storage")).font(.headline)
- 334: Text(L10n.text("%@ free", DownloadFormat.size(free))).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
- 338: Text(DownloadFormat.size(downloads)).font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
- 339: Text(L10n.text("used by downloads")).font(.subheadline).foregroundStyle(.secondary)
- 361: .font(.caption)
- 364: Text(L10n.text("tvOS may remove downloads when Apple TV runs low on storage.")).font(.caption).foregroundStyle(.secondary)
- 426: Text(item.title).font(.body.weight(.semibold)).lineLimit(1).help(item.title)
- 428: Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 443: Text(status(compact: false)).font(.caption).monospacedDigit().lineLimit(1)
- 465: Image(systemName: symbol).font(.system(size: 22)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
- 481: Text(item.title).font(.headline).lineLimit(1)
- 482: Text(item.episode).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
- 492: .font(.caption).monospacedDigit()
- 535: Image(systemName: symbol).font(.system(size: DownloadMetrics.thumb > 60 ? 24 : 13, weight: .semibold)).frame(width: DownloadMetrics.thumb > 60 ? 32 : 18)
- 557: Text(show.title).font(.headline).lineLimit(2)
- 559: .font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 566: Label(L10n.text("Delete Downloads"), systemImage: "trash").font(.subheadline)
- 581: Image(systemName: "play.fill").font(.system(size: DownloadMetrics.thumb > 60 ? 18 : 10)).foregroundStyle(.secondary)
- 584: if let quality = item.quality { Text(quality).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
- 585: Text(DownloadFormat.size(item.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
- 667: .font(.system(size: DownloadMetrics.thumb > 60 ? 22 : 12, weight: .semibold))
- 703: .font(.system(size: size))
- 740: Text(L10n.text("Download Episodes")).font(.title2.weight(.bold))
- 741: Text(video.name).font(.headline).lineLimit(2)
- 742: if !flag.isEmpty { Text(SourceLabel(flag).text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
- 754: Text(L10n.text("%@ free", DownloadFormat.size(free))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
- 818: Text(L10n.text("Download Episodes")).font(.title3.weight(.semibold))
- 819: Text(video.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
- 821: Text(macSubtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
- 844: Text(L10n.text("%@ free", DownloadFormat.size(free))).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
- 937: .font(.system(size: 15))
- 944: .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
- 973: Text(existing.status == .completed ? L10n.text("Downloaded") : L10n.text("In Queue")).font(.caption).foregroundStyle(.secondary)

## Addendum — applied-edit notes (post-inventory)
- Containers bumped one Dynamic Type step for implicit-font rows: SettingsPage .xLarge→.xxLarge (SettingsView.swift), settings hub .xLarge→.xxLarge (LocalSettingsView.swift), home source panel .xLarge→.xxLarge (LocalHomeSourcePanel.swift).
- Base constants bumped: DiscoverLayout non-tvOS heading 16→18 / caption 13→15 / secondary 11→13 / captionHeight 46→50 / headingHeight 32→34 (DiscoverTVLayout.swift); Layout.heroTitle iOS 34→36 (GlassKit.swift) and HomeView regular-width hero 52→54.
- URL TextFields given explicit .system(size: 21): LocalSourceSettingsView add-source address field + LocalSourceEditor address field, LocalDanmakuAPISettings API-address field, TMDBServiceSettingsView API/图片/代理 address fields.
- Manual ternary-weight conversions: DiscoveryView.swift:66 and DiscoverCalendarView.swift:213 (.subheadline.weight(ternary) → .system(size: 17, weight: ternary)); DiscoveryView SourceChip size ternary 14/11→16/13.
- Layout raises (text would otherwise clip): DiscoverView hero — genre/date line frame height 17→20 (font 14→16), overview frame 34→40 (12→14, 2 lines), rating row frame 14→17 (11→13).
- Relative-style fonts (.system(.footnote/.body/.title, design:)) converted once (+2): SettingsView licenses monospaced footnote → 15, Diagnostics message → 19 monospaced; DownloadsView storage figure → 30 rounded bold.
- NOT bumped on purpose: SF Symbol icon fonts (Image(systemName:) .font specs), tvOS/macOS-only branches, scaled glyph expressions derived from tile sizes (MonogramIcon/SourceRankBadge/ChannelLogo letters, PluginNodeView data-driven sizes), DiscoverArtwork.swift (change 1).

## Amendment (user decision, same sweep) — Music, Favourites, Push in scope; Dock-settings icons +1 step

Pre-amendment font specs in the added files (from HEAD, before this amendment's edits):


### App/MusicView.swift — 25 font spec(s)
- 394: Image(systemName: "music.note.list").font(.title2).foregroundStyle(Brand.accent)
- 397: Text("我的歌单").font(.headline)
- 398: Text("收藏的歌单与专辑 · \(library.favoriteCollections.count)").font(.subheadline).foregroundStyle(.secondary)
- 415: .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 8)
- 463: Text(L10n.text("Continue Playing")).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
- 464: Text(track.title).font(.headline).lineLimit(1)
- 467: .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
- 470: Image(systemName: "play.circle.fill").font(.system(size: MusicLayout.art * 0.6)).foregroundStyle(Brand.accent)
- 496: Text("\(number)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
- 502: Text(track.title).font(.headline).lineLimit(1)
- 505: .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
- 518: .font(.system(size: DownloadState.size, weight: .semibold))
- 527: .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
- 563: Text(collection.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
- 564: Text(MusicCollectionView.details(collection)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
- 567: Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
- 651: Text(L10n.text(collection.kind == .album ? "Album" : "Playlist")).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
- 652: Text(collection.title).font(.title2.weight(.bold)).lineLimit(2)
- 653: Text(Self.details(collection)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
- 699: .font(.system(size: MusicLayout.art * 0.46, weight: .semibold)).foregroundStyle(.white)
- 705: Text(MusicLikedView.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
- 706: Text(L10n.text("%lld songs", count)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
- 709: Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
- 777: Text(Self.title).font(.largeTitle.weight(.bold))
- 780: .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)

### App/MusicPlayerViews.swift — 26 font spec(s)
- 108: Text(music.track?.title ?? "").font(.headline).lineLimit(1)
- 110: .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
- 156: .font(.subheadline.weight(.medium)).lineLimit(1)
- 188: .font(.caption.weight(.medium)).monospacedDigit().lineLimit(2)
- 195: Text(L10n.text("Source: GD Music (music.gdstudio.xyz)")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
- 197: Text(L10n.text("Source: Xinghai (yy.zddyr.top)")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
- 283: Text(MusicTime.text(scrubbing ?? music.seekingTo ?? music.position)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
- 298: Text(music.duration.map(MusicTime.text) ?? "--:--").font(.caption).monospacedDigit().foregroundStyle(.secondary)
- 368: .font(.system(size: size, weight: .bold))
- 371: Text(translation).font(.system(size: translationSize, weight: .semibold)).foregroundStyle(.white.opacity(active ? 0.7 : 0.25))
- 375: Text(romanization).font(.system(size: translationSize)).foregroundStyle(.white.opacity(active ? 0.65 : 0.25))
- 379: .font(.system(size: size, weight: active ? .bold : .semibold))
- 382: Text(translation).font(.system(size: translationSize)).foregroundStyle(active ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
- 386: Text(romanization).font(.system(size: translationSize)).foregroundStyle(active ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
- 404: Text(L10n.text("Lyrics from %@", lyrics.platform.name)).font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
- 455: .font(.body.weight(.semibold))
- 459: Text(row.candidate.name).font(.body.weight(.medium))
- 460: Text(row.detail).font(.caption).foregroundStyle(.secondary)
- 577: Text(detail).font(.caption).foregroundStyle(.secondary)
- 654: Text(title).font(.title3.weight(.semibold)).lineLimit(1)
- 689: .font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
- 741: .font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
- 895: Text(MusicLXSourcesModel.detail(source)).font(.caption).foregroundStyle(.secondary)
- 917: Text(message).font(.caption).foregroundStyle(model.failed ? Brand.amber : Color.secondary)
- 1111: if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
- 1133: Text(message).font(.caption).foregroundStyle(model.failed ? Brand.amber : Color.secondary)

### App/MusicDownloadsView.swift — 18 font spec(s)
- 141: if !embedded { Text(Self.title).font(.largeTitle.weight(.bold)) }
- 144: .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
- 253: Text(L10n.text(collection.kind == .album ? "Album" : "Playlist")).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
- 254: Text(collection.title).font(.title2.weight(.bold)).lineLimit(2)
- 256: .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
- 302: Text(collection.title).font(Self.titleFont).foregroundStyle(.primary).lineLimit(1)
- 303: Text(L10n.text("%lld songs", saved)).font(Self.subtitleFont).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
- 322: private static let titleFont = Font.system(size: 24, weight: .semibold), subtitleFont = Font.system(size: 20)
- 324: private static let titleFont = Font.subheadline.weight(.medium), subtitleFont = Font.caption
- 355: .font(.subheadline.weight(.semibold))
- 390: Text(item.track.title).font(.headline).lineLimit(1)
- 391: Text(status).font(.subheadline).monospacedDigit().lineLimit(2)
- 400: Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)).frame(width: 30, height: 30).contentShape(.rect).iosTouchTarget()
- 407: Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
- 448: .font(.system(size: MusicLayout.art * 0.46, weight: .semibold)).foregroundStyle(.white)
- 454: Text(MusicDownloadsView.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
- 455: Text(details(library)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
- 458: Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)

### App/MusicMiniPlayer.swift — 5 font spec(s)
- 48: Text(music.track?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
- 50: Text(failure).font(.caption).foregroundStyle(Brand.amber).lineLimit(1)
- 52: Text(music.track?.artistLine ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
- 83: button("xmark", label: "Stop") { music.stop() }.font(.body).foregroundStyle(.secondary)
- 86: .font(.title3)

### App/MusicNowPlayingScreen.swift — 11 font spec(s)
- 109: Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
- 130: Text(music.track?.title ?? "").font(.system(size: short ? 16 : 18, weight: .bold)).lineLimit(1)
- 131: Text(music.track?.artistLine ?? "").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
- 145: Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
- 162: .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).foregroundStyle(.secondary)
- 168: Button(action: action) { Image(systemName: symbol).font(.system(size: size)).frame(width: 44, height: 44).contentShape(Rectangle()) }
- 175: Image(systemName: store.music.playbackMode.symbol).font(.system(size: 19))
- 185: Image(systemName: "list.bullet").font(.system(size: 20)).foregroundStyle(.white.opacity(0.65)).frame(width: 48, height: 44)
- 276: Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 24)
- 277: Text(L10n.text(title)).font(.body.weight(.medium))
- 330: .font(.caption)

### App/MusicNowPlayingPanels.swift — 10 font spec(s)
- 44: Text(L10n.text("Lyrics from %@", lyrics.platform.name)).font(.caption2).foregroundStyle(.white.opacity(0.3)).padding(.top, 8)
- 96: Image(systemName: "music.note").font(.system(size: 25)).foregroundStyle(.white.opacity(0.4))
- 97: Text(L10n.text("No Lyrics")).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.6))
- 106: Text(line.text.isEmpty ? "♪" : line.text).font(.system(size: size, weight: selected ? .bold : .medium))
- 109: Text(translation).font(.system(size: compact ? 12 : baseTranslation, weight: .medium)).foregroundStyle(.white.opacity(selected ? 0.72 : 0.46))
- 114: Text(romanization).font(.system(size: compact ? 11 : baseTranslation, weight: .regular))
- 150: Text(L10n.text("Up Next")).font(.headline).padding(.bottom, 6)
- 157: Text(track.title).font(.body.weight(.medium)).lineLimit(1)
- 158: Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
- 162: Text(MusicTime.text(duration)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)

### App/MusicMacBrowse.swift — 21 font spec(s)
- 84: Text(title).font(.title3.weight(.bold)).foregroundStyle(.primary)
- 85: Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
- 112: Text(collection.title).font(Self.titleFont).foregroundStyle(.primary).lineLimit(1)
- 113: Text(collection.subtitle ?? collection.platform.name).font(Self.subtitleFont).foregroundStyle(.secondary).lineLimit(1)
- 131: private static let titleFont = Font.system(size: 24, weight: .semibold), subtitleFont = Font.system(size: 20)
- 133: private static let titleFont = Font.subheadline.weight(.medium), subtitleFont = Font.caption
- 135: private static let titleFont = Font.system(size: 12, weight: .medium), subtitleFont = Font.system(size: 11)
- 185: Text(title).font(.largeTitle.weight(.bold))
- 310: Text(track.title).font(.system(size: title, weight: .medium)).lineLimit(1)
- 312: Text(track.artistLine).font(.system(size: artist)).foregroundStyle(.secondary).lineLimit(1)
- 326: .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
- 354: Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
- 386: .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
- 419: else if hovering { Image(systemName: "play.fill").font(.system(size: 11)) }
- 422: .font(.system(size: 12)).foregroundStyle(.secondary)
- 442: .font(.system(size: 13))
- 466: Text(title).font(.largeTitle.weight(.bold))
- 492: Text(collection.title).font(.system(size: 26, weight: .bold)).lineLimit(2)
- 494: Text(subtitle).font(.system(size: 22)).lineLimit(1)
- 497: Text(details).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
- 534: .font(.system(size: 13, weight: .semibold))

### App/FavoriteControls.swift — 2 font spec(s)
- 19: .font(onArtwork ? .system(size: 13, weight: .semibold) : .title3)
- 86: Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)

### App/LocalPushView.swift — 3 font spec(s)
- 44: if let localFile { Text(localFile.lastPathComponent).font(.footnote) }
- 60: Text("先检查所选站点是否支持，再读取真实资源和播放线路。").font(.footnote).foregroundStyle(.secondary)
- 196: if let localError { Text(localError).font(.footnote).foregroundStyle(.red).padding() }

### Added-scope notes
- MusicMacMiniPlayer.swift / MusicMacPlayer.swift / MusicTVPlayer.swift / MusicTVScreen.swift / MusicPlaybackSession.swift / MusicRemoteControl.swift / MusicVinylArtwork.swift: 0 changes — macOS/tvOS-only or no font specs. MusicMacBrowse.swift: only its non-macOS branches changed (3 lines).
- Favourites page = FavoritesView in App/LiveView.swift (already bumped in the main sweep) + App/FavoriteControls.swift (favorite button: onArtwork 13 semibold → 15 semibold; on-card .title3 → 22).
- Push page = App/LocalPushView.swift (3 footnote texts 13 → 15; remaining push text is implicit-font).
- Music now-playing is a music page (presented from RootView as a full-screen cover), NOT the video player: MusicNowPlayingScreen/Panels bumped. No Music component is used by PlayerView/PlaybackView/MobilePlayer, so there is no video-player spillover. MusicMiniPlayer's two transport-glyph fonts (.body/.title3 on icon-only buttons) were left unchanged on purpose (icon glyphs, not text).
- Lyrics sizes in MusicNowPlayingPanels are computed from base constants: non-macOS baseSize 24→26, baseTranslation 14→16; compact translation 12→14, romanization 11→13. MusicNowPlayingScreen title ternary short ? 16 : 18 → 18 : 20.
- Music source-credit captions showing domain names (e.g. "Source: GD Music (music.gdstudio.xyz)", MusicPlayerViews) are credit labels, bumped +2 like other music text, not +4 (the +4 class was the settings/source/danmaku address elements defined in the main sweep).

## Dock 按钮 settings-page icon bump (+1 step)
- Page: LocalDockButtonsSettingsView in App/LocalDockButtons.swift (Settings → Dock 按钮; rows 首页/收藏/历史/直播/音乐/设置/搜索/推送).
- Leading row icon: `Image(systemName: button.dockIcon).font(.system(size: 19, weight: .semibold)).frame(width: 30)` → glyph 19→21pt, frame width 30→32pt. (Row text on the same page was already bumped in the main sweep: title 17→19, 常驻 caption 12→14.)
- The icon spec is a local literal in this view only — it does NOT share a component/token with other settings-list rows (settings hub uses MonogramIcon tiles; form rows use SettingsIcon/FormMetrics), so no cross-settings icon change was made.
- The bottom Dock itself does not use this literal (dock glyphs render from AppSection icons elsewhere); the Dock is unchanged.

