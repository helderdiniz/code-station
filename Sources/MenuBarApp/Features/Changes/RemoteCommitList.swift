import SwiftUI

struct RemoteCommitList: View {
    let commits: [GitRemoteCommit]
    let emptyMessage: String

    var body: some View {
        if commits.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("COMMITS", tint: Theme.secondaryText)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(commit.shortID)
                                    .font(.mono(11, .medium))
                                    .foregroundStyle(Theme.secondaryText)
                                Text(commit.subject)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                            .arrives(after: Double(min(index, 3)) * 0.028, rising: 4)
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }

}
