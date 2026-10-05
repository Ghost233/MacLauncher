/// Project binding lookup used during handshake.
///
/// The real binding store arrives with the project-binding feature; the
/// handshake only needs to know whether a project identity is bound.
abstract class BindingLookup {
  bool isKnownProject(String projectId);
}

class InMemoryBindingLookup implements BindingLookup {
  InMemoryBindingLookup(Iterable<String> projectIds)
    : _ids = projectIds.toSet();

  final Set<String> _ids;

  void add(String projectId) => _ids.add(projectId);

  void remove(String projectId) => _ids.remove(projectId);

  @override
  bool isKnownProject(String projectId) => _ids.contains(projectId);
}
