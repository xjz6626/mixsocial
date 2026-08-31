import 'models.dart';

abstract interface class FeedSource {
  SourceId get id;
  Set<SourceCapability> get capabilities;

  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''});
  Future<FeedPage> search(String query, {String cursor = ''});
  Future<FeedDetail> detail(ContentRef ref);
}

abstract interface class ForumReader {
  Future<FeedPage> forum(String forum, {String cursor = '', int sortType = 0});
  Future<FeedPage> searchForum(
    String forum,
    String query, {
    String cursor = '',
  });
  Future<List<String>> followingForums();
}

abstract interface class ThreadPageReader {
  Future<FeedDetail> detailPage(
    ContentRef ref, {
    String cursor = '',
    bool reverse = false,
    bool onlyOriginalPoster = false,
  });
}

abstract interface class FloorReplyReader {
  Future<FeedCommentPage> floorReplies(ContentRef floor, {String cursor = ''});
}

abstract interface class ProfileReader {
  Future<ProfilePage> profile(
    ProfileRef profile, {
    ProfileSection section = ProfileSection.notes,
    String cursor = '',
  });
}

abstract interface class ContentInteractor {
  Future<void> like(ContentRef ref, bool value);
  Future<void> favorite(ContentRef ref, bool value);
  Future<void> comment(ContentRef ref, String body);
  Future<void> reply(ContentRef ref, ContentRef comment, String body);
}

abstract interface class RelationshipInteractor {
  Future<void> follow(ProfileRef profile, bool value);
}
