import 'models.dart';

abstract interface class FeedSource {
  SourceId get id;
  Set<SourceCapability> get capabilities;

  Future<FeedPage> browse(FeedChannel channel, {String cursor = ''});
  Future<FeedPage> search(String query, {String cursor = ''});
  Future<FeedDetail> detail(ContentRef ref);
}

abstract interface class ContentInteractor {
  Future<void> like(ContentRef ref, bool value);
  Future<void> favorite(ContentRef ref, bool value);
  Future<void> comment(ContentRef ref, String body);
  Future<void> reply(ContentRef ref, ContentRef comment, String body);
}

abstract interface class RelationshipInteractor {
  Future<void> follow(ProfileRef profile, bool value);
  Future<void> block(ProfileRef profile, bool value);
}
