![platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20MacOS%20%7C%20Linux-brightgreen)
![last-commit](https://img.shields.io/github/last-commit/bingxizhe/JHenTai)
![star](https://img.shields.io/github/stars/bingxizhe/JHenTai)
[![issue](https://img.shields.io/badge/chat-issue-brightgreen)](https://github.com/bingxizhe/JHenTai/issues/new)

# JHenTai (Fork)

[English](README.md) | [简体中文](README_cn.md) | 한국어

이 저장소는 [JHenTai](https://github.com/jiangtian616/JHenTai)의 Fork로, Android, iOS, Windows, MacOS, Linux를 지원하는 E-Hentai 만화 애플리케이션입니다.

이 Fork는 **다운로드 관리 강화**, **로컬 갤러리 관리**, **일괄 작업**에 중점을 둡니다. 모든 변경사항은 비침투적으로 설계되었으며 상위 코드베이스와 호환되고, 정기적으로 상위 업데이트를 병합합니다.

## Fork 기능

### 1. 갤러리 버전 체인 관리

상위는 단일 홉 부모 버전 URL만 저장합니다. 이 Fork는 전체 조상 체인으로 확장하여, 중간 버전이 삭제되어도 다중 홉 버전 관계를 인식할 수 있습니다.

- **전체 조상 체인**: `oldVersionGalleryUrl`이 전체 조상 체인(부모 → 조부모 → …, 최대 20레벨)의 JSON 배열로 저장됩니다. 새 갤러리 다운로드 시 백그라운드에서 자동으로 체인을 크롤링하고 영속화하며, 조상이 로컬에 이미 있으면 단락 최적화됩니다.
- **이전 버전 일괄 삭제**(`eh_delete_history_versions_dialog.dart`): 조상 체인으로 다운로드된 갤러리를 그룹화하고, 각 그룹의 최신 버전을 제외한 모든 이전 버전을 기본 선택하여 원클릭 일괄 삭제합니다. 로컬에 기록되지 않은 버전 관계를 발견하는 "심층 스캔"을 지원하며, 24시간 결과 캐싱 및 듀얼 사이트(e-hentai/exhentai) 폴백을 제공합니다.
- **이전 버전 링크 가져오기**(`eh_fetch_old_version_urls_dialog.dart`): 모든 다운로드된 갤러리의 전체 조상 체인을 온라인에서 재귀적으로 크롤링하며, 듀얼 사이트 폴백을 제공합니다. 이전 단일 링크 레코드를 전체 체인 형식으로 자동 업그레이드합니다.
- **도메인 무관 매칭**: gid+token으로 버전 관계를 매칭하여 도메인 차이를 무시하고, e-hentai.org와 exhentai.org URL 혼용을 처리합니다.

### 2. 다운로드 복원 견고성

- **지연 복원**: 다운로드 복원이 앱 시작 시 실행되지 않고, 다운로드 페이지 첫 진입 시 `ensureRestored()`를 통해 트리거되어, 대규모 디렉토리(수천 갤러리)가 앱 시작을 차단하는 것을 방지합니다.
- **복원 진행 베너**: 다운로드 페이지에 단계별 진행률("갤러리 데이터 파싱 x/y", "갤러리 로딩 x/y")을 표시합니다.
- **일괄 복원 모드**: 3000+ 갤러리 복원 시 개별 갤러리 `update()` 호출을 억제하고, 간격별로 UI를 일괄 새로고침합니다.
- **비동기 I/O 복원**: 복원 작업이 동기 `listSync`/`readAsStringSync` 대신 비동기 파일 I/O를 사용하여 UI 스레드 차단을 방지합니다.
- **이미 로딩된 갤러리 건너뛰기**: 디렉토리 이름에서 gid를 추출하여 DB에서 이미 로딩된 갤러리의 메타데이터 파싱을 건너뜁니다.
- **메타데이터 일관성 검증**(`verifyDownloadedGalleriesMetadata`): 다운로드 디렉토리를 스캔하여 sanitizedTitle 불일치, 만료된 이미지 경로, 중복 디렉토리 진동을 수정합니다. 또한 이전 verify 오류로 paused로 잘못 재설정된 갤러리(curCount=0이지만 표지 파일 존재)를 복구합니다.
- **고아 디렉토리 정리**: 갤러리 삭제 시 sanitizedTitle이 디스크 디렉토리 이름과 불일치하면 gid 접두사 매칭으로 폴백하여 디렉토리를 삭제하고, 고아 디렉토리가 verify에 의해 재임포되는 것을 방지합니다.

### 3. 즐겨찾기 일괄 다운로드

- **원클릭 일괄 다운로드**: 특정 그룹의 모든 즐겨찾기를 한 번에 다운로드하며, 이미 다운로드된(일반 또는 아카이브) 갤러리를 자동으로 건너뜁니다.
- **중단점 이어받기**: 30분 이내 중단점 이어받기를 지원합니다. 로딩/다운로드 실패 시 진행률이 저장되고, 카운트다운 베너와 "계속" 버튼이 표시됩니다.
- **다운로드 전 대화상자**: 일괄 다운로드 전에 대상 다운로드 그룹과 원본 이미지 다운로드 여부를 선택합니다.
- **진행 베너**: 상단에 "모든 즐겨찾기 로딩 x" 및 "일괄 다운로드 x/y" 진행률을 표시합니다.
- **재시도 메커니즘**: 페이지 로딩과 개별 갤러리 큐잉 모두 5회 재시도하며, 재시도 간격은 각각 2초, 500ms입니다.
- **증분 영속화**: 즐겨찾기 목록을 매 페이지가 아닌 5페이지마다 저장하여, 대규모 컬렉션의 O(n²) 직렬화 오버헤드를 감소시킵니다.

### 4. 로컬 갤러리 관리

- **지연 스캔**: 로컬 갤러리 스캔이 앱 시작을 차단하지 않고, 다운로드 페이지 첫 진입 시 `ensureScanned()`를 통해 트리거됩니다.
- **스캔 진행 표시**: 스캔 중 "스캔한 디렉토리 수 / 전체" 및 "발견된 갤러리 수"를 표시합니다.
- **로딩 상태 표시**: 로컬 갤러리 페이지가 `LoadingStateIndicator`를 사용하여 스캔 로딩 상태와 진행 텍스트를 표시합니다.
- **전체 디렉토리 삭제**: 로컬 갤러리 삭제 시 항상 전체 디렉토리(비이미지 파일 및 메타데이터 포함)를 삭제하여, 빈 폴더나 반삭제 상태가 남는 것을 방지합니다.
- **비동기 스캔 리팩터**: 스캔 로직이 진행 콜백과 함께 async/await 구조로 재구성되어, 중첩 Completer 패턴을 대체합니다.

### 5. UI/UX 개선

- **반응형 다운로드 아이콘**: 갤러리 카드 다운로드 아이콘이 반응형으로 변경되어, `GalleryDownloadService` 및 `ArchiveDownloadService` 상태 변화를 수신합니다. 다운로드/아카이브 완료 시 아이콘이 즉시 업데이트됩니다(이전에는 일회성 `downloaded` 판별 기반으로 상태 변화에 따라 업데이트되지 않음).
- **텍스트 오버플로 수정**: 댓글 작성자명, dashboard 카드, 다운로드 목록 업로더명, 갤러리 카드 시간 등 긴 텍스트가 `Flexible` + `maxLines:1` + `overflow:ellipsis`를 사용하여 오버플로를 수정합니다.
- **서드파티 뷰어 오류 판정**: `openThirdPartyViewer`가 0이 아닌 종료 코드로만 오류를 판정하여, Chromium/Electron류 뷰어의 stderr 노이즈(예: GPU 캐시 실패)가 오탐으로 처리되는 것을 방지합니다.

### 6. 성능 및 엔지니어링

- **시작 성능 로깅**: 각 `JHLifeCircleBean.initBean`의 소요 시간을 기록하고, 50ms 초과 시 trace 레벨로 로깅하며, 총 초기화 시간도 기록합니다.
- **데이터베이스 WAL 모드**: `PRAGMA journal_mode = WAL` 및 `busy_timeout = 5000`을 활성화하여 동시 읽기/쓰기 성능을 향상시킵니다.
- **이미지 삽입 또는 교체**: `insertImage`를 `InsertMode.insertOrReplace`로 변경하여 중복 삽입 충돌을 수정합니다.
- **최근 갤러리 그룹 수 제한**: 최근 갤러리 그룹 수를 최대 10개로 제한합니다.
- **커스텀 삽입 시간**: `GalleryDownloadRequest`에 `insertTime` 필드를 추가하여, 일괄 즐겨찾기 다운로드 시 우선순위 스케줄러가 개별 다운로드하도록 시간을 분산시킵니다.
- **새 버전 URL 선택 최적화**: `newVersionGalleryUrl`이 마지막 것을 가져오는 대신 updateTime으로 정렬하여 최신 하위 버전을 선택합니다.

## 다운로드 및 설치

안정 버전은 [원본 프로젝트 Releases](https://github.com/jiangtian616/JHenTai/releases)를 참조하세요.

소스에서 빌드:

1. Android 서명을 직접 관리해야 합니다: https://docs.flutter.dev/deployment/android#signing-the-app
2. IDEA 또는 VSCode에서 직접 실행하세요.

## 주요 Dart 종속성

- [get](https://pub.flutter-io.cn/packages/get): 종속성 관리, 상태 관리, l18n, NoSQL
- [dio](https://pub.flutter-io.cn/packages?q=dio): 네트워크
- [extendedImage](https://pub.flutter-io.cn/packages/extended_image): 이미지
- [drift](https://pub.flutter-io.cn/packages/drift): 데이터베이스

## 참조 및 감사

- [JHenTai](https://github.com/jiangtian616/JHenTai) - 원본 프로젝트
- [FEhviewer](https://github.com/honjow/FEhViewer) - 레이아웃 스타일 참조
- [EHPanda](https://github.com/tatsuz0u/EhPanda) - 레이아웃 스타일 참조
- [EhTagTranslation](https://github.com/EhTagTranslation/Database) - 태그 번역
