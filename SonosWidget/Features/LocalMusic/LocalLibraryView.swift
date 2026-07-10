import MusicKit
import Observation
import SwiftUI

struct LocalLibraryView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager
    @State var store = LocalLibraryStore()
    @State var searchText = ""
    @State var searchScope: LocalServiceSearchScope = .library
    @State var submittedSearchText = ""
    @State var searchSubmissionID = 0
    @State var hasSubmittedSearch = false
    @State var catalogSearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
    @State var librarySearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
    @State var categoryDetailSearchText = ""
    @State var categorySortSelections: [LocalLibraryCategory: LocalLibraryCategorySortOption] = [:]
    @State var songDetailPresentationCache = LocalLibraryCategoryDetailPresentationCache<Song>()
    @State var albumDetailPresentationCache = LocalLibraryCategoryDetailPresentationCache<Album>()
    @State var pullRefreshController = LocalLibraryPullRefreshController()
    @FocusState var isCategorySearchFieldFocused: Bool
    @Namespace var catalogCategorySelectionNamespace
    @Namespace var librarySearchCategorySelectionNamespace

    let scrollCoordinateSpaceName = "local-library-scroll"

    var isSearchingLibrary: Bool {
        !trimmedSearchText.isEmpty
    }

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedCategoryDetailSearchText: String {
        categoryDetailSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isAccessDenied {
                    deniedContent
                } else if store.isLoading && !store.hasLoaded {
                    loadingContent
                } else if !store.hasHomeContent && trimmedSearchText.isEmpty {
                    emptyLibraryContent
                } else {
                    content
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: LocalLibraryCategory.self) { category in
                libraryCategoryDetail(category)
                    .background(backgroundLayer.ignoresSafeArea())
                    .preferredColorScheme(.dark)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .background(backgroundLayer.ignoresSafeArea())
            .searchable(
                text: $searchText,
                prompt: LocalServiceSearchPresentation.prompt(for: searchScope)
            )
            .searchScopes($searchScope) {
                ForEach(LocalServiceSearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .onSubmit(of: .search) {
                submitSearch()
            }
            .onChange(of: searchText) { _, newValue in
                handleSearchTextChanged(newValue)
            }
            .onChange(of: searchScope) { _, _ in
                handleSearchScopeChanged()
            }
            .onChange(of: store.catalogSearchResults.items) { _, _ in
                selectCatalogCategoryForAvailableResults()
            }
            .onChange(of: store.summary) { _, _ in
                selectLibrarySearchCategoryForAvailableResults()
            }
            .task {
                await store.loadIfNeeded()
            }
            .task(id: "\(searchScope.rawValue):\(submittedSearchText):\(searchSubmissionID)") {
                await store.search(term: submittedSearchText, scope: searchScope)
            }
            .preferredColorScheme(.dark)
        }
    }

    func submitSearch() {
        let trimmed = trimmedSearchText
        guard !trimmed.isEmpty else {
            resetSubmittedSearch()
            return
        }

        if searchText != trimmed {
            searchText = trimmed
        }

        submittedSearchText = trimmed
        hasSubmittedSearch = true
        searchSubmissionID += 1

        if searchScope == .appleMusic {
            catalogSearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        } else {
            librarySearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        }
    }

    func handleSearchTextChanged(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetSubmittedSearch()
            return
        }

        if !submittedSearchText.isEmpty && trimmed != submittedSearchText {
            resetSubmittedSearch()
        }
    }

    func handleSearchScopeChanged() {
        if searchScope == .appleMusic {
            catalogSearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        } else {
            librarySearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        }

        if hasSubmittedSearch && !submittedSearchText.isEmpty {
            searchSubmissionID += 1
        }
    }

    func resetSubmittedSearch() {
        let hadSubmittedSearch = hasSubmittedSearch || !submittedSearchText.isEmpty
        hasSubmittedSearch = false
        submittedSearchText = ""
        catalogSearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists
        librarySearchCategory = LocalServiceSearchPresentation.catalogCategoryOrder.first ?? .artists

        if hadSubmittedSearch {
            searchSubmissionID += 1
        }
    }

    func selectCatalogCategoryForAvailableResults() {
        guard searchScope == .appleMusic, hasSubmittedSearch else { return }
        guard store.catalogSearchResults.count(for: catalogSearchCategory) == 0 else { return }
        guard let firstCategoryWithResults = LocalServiceSearchPresentation.catalogCategoryOrder.first(
            where: { store.catalogSearchResults.count(for: $0) > 0 }
        ) else {
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            catalogSearchCategory = firstCategoryWithResults
        }
    }

    func selectLibrarySearchCategoryForAvailableResults() {
        guard searchScope == .library, hasSubmittedSearch else { return }
        guard store.displayedSnapshot.summary.count(for: librarySearchCategory) == 0 else { return }
        guard let firstCategoryWithResults = LocalServiceSearchPresentation.catalogCategoryOrder.first(
            where: { store.displayedSnapshot.summary.count(for: $0) > 0 }
        ) else {
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            librarySearchCategory = firstCategoryWithResults
        }
    }

}
