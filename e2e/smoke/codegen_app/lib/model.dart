import 'package:copy_with_extension/copy_with_extension.dart';

// Generated in-action by build_runner via copy_with_extension_gen; the
// generated part is never checked in.
part 'model.g.dart';

@CopyWith()
class Greeting {
  const Greeting({required this.message, this.count = 0});

  final String message;
  final int count;
}
