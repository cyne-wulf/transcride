enum ListSelectionNavigator {
    static func adjacentID<ID: Equatable>(
        in ids: [ID],
        selectedID: ID?,
        offset: Int
    ) -> ID? {
        guard !ids.isEmpty, offset != 0 else { return nil }
        guard let selectedID,
              let currentIndex = ids.firstIndex(of: selectedID) else {
            return offset > 0 ? ids.first : ids.last
        }
        let nextIndex = min(ids.count - 1, max(0, currentIndex + offset))
        return ids[nextIndex]
    }
}
