import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  const original =
      'https://res.cloudinary.com/example/image/upload/v1700000000/one_one/profile_photos/abc.jpg';
  const versioned =
      '$original?one_one_v=1700000000';

  test('inserts format/quality/size transforms before the public id', () {
    expect(
      CloudinaryDelivery.urlFor(versioned, pixelSize: 96),
      'https://res.cloudinary.com/example/image/upload/f_auto,q_auto,c_limit,w_96,h_96/v1700000000/one_one/profile_photos/abc.jpg?one_one_v=1700000000',
    );
  });

  test('snaps odd pixel sizes to CDN-friendly steps and never exceeds 512', () {
    expect(CloudinaryDelivery.snapPixelSize(40), 64);
    expect(CloudinaryDelivery.snapPixelSize(70), 96);
    expect(CloudinaryDelivery.snapPixelSize(200), 256);
    expect(CloudinaryDelivery.snapPixelSize(400), 512);
    expect(CloudinaryDelivery.snapPixelSize(1600), 512);
  });

  test('leaves non-Cloudinary URLs and already-transformed URLs alone', () {
    const other = 'https://example.com/photo.jpg';
    expect(CloudinaryDelivery.urlFor(other, pixelSize: 128), other);

    const transformed =
        'https://res.cloudinary.com/example/image/upload/w_128,h_128,c_fill/v1/photo.jpg';
    expect(
      CloudinaryDelivery.urlFor(transformed, pixelSize: 256),
      transformed,
    );
  });
}
