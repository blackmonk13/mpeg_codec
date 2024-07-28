
A package for handling MP4 and ID3 metadata and related operations.

## Features

The package can perform the following tasks:
- Read MP4 and ID3 metadata from files that support MP4 and ID3 codecs.
- Add, update and remove MP4 and ID3 metadata.

## Usage

Initialize the respective handlers. 

#### MP4
```dart
final handler = MP4Handler(filePath);
print(handler.metadata);
```
#### ID3
```dart
final handler = ID3Handler(filePath);
print(handler.metadata);
```
#### Encoding metadata
Encoding metadata is simple
```dart
// Queue multiple operations
handler.addMetadata({
'title': 'New Title',
'artist': 'Artist',
});
handler.updateMetadata({'genre': 'New Genre'});
handler.removeMetadata(['artist']);

try {
// Apply all queued changes at once
await handler.applyMetadataChanges();
print('Metadata changes applied successfully');
} catch (e) {
print('Failed to apply metadata changes: $e');
}
```

## Metadata

| MP4         | ID3         |
| ----------- | ----------- |
| title       | title       |
| artist      | artist      |
| album       | album       |
| year        | year        |
| genre       | genre       |
| composer    | composer    |
| lyrics      | lyrics      |
| comment     | comments    |
| albumArtist | albumArtist |
| trackNumber | trackNumber |
| discNumber  | discNumber  |
| cover       | picture     |
| description |             |
| copyright   | copyright   |
| rating      | rating      |

 
