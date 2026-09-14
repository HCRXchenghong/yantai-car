import 'package:flutter_test/flutter_test.dart';

import 'package:esp32_car_controller/main.dart';

void main() {
  test('differential mixer maps the joystick axes to both motors', () {
    final forward = differentialMix(throttle: 1, steering: 0);
    expect(forward.left, 1);
    expect(forward.right, 1);

    final backward = differentialMix(throttle: -1, steering: 0);
    expect(backward.left, -1);
    expect(backward.right, -1);

    final leftTurn = differentialMix(throttle: 0, steering: -1);
    expect(leftTurn.left, -1);
    expect(leftTurn.right, 1);

    final rightTurn = differentialMix(throttle: 0, steering: 1);
    expect(rightTurn.left, 1);
    expect(rightTurn.right, -1);
  });

  test('maps screen axes to the measured chassis frame', () {
    final up = carJoystickMix(x: 0, y: -1);
    expect(up.left, 0);
    expect(up.right, 1);

    final left = carJoystickMix(x: -1, y: 0);
    expect(left.left, 1);
    expect(left.right, 0);
  });

  testWidgets('connect page renders', (WidgetTester tester) async {
    await tester.pumpWidget(const CarControllerApp());

    expect(find.text('连接小车'), findsOneWidget);
    expect(find.text('192.168.4.1'), findsNWidgets(2));
  });
}
