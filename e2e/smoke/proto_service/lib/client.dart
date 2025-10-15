import 'package:services_api_v1_proto_dart/service.pb.dart';

String buildGreeting(String name) {
  final request = GreetingRequest()..name = name;
  final response = GreetingResponse()..message = 'Hello, ${request.name}!';
  return response.message;
}
