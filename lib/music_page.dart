import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'downloads_service.dart';
import 'jiosaavn_service.dart';

const _musicAccent = Color(0xFF38DAD5);

Future<void> _downloadSaavn(BuildContext context, SaavnSong song) async {
  final quality = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.all(16), child: Text('Download quality', style: Theme.of(ctx).textTheme.titleLarge)),
      for (final q in ['320', '160', '96'])
        ListTile(leading: const Icon(Icons.audio_file), title: Text('$q kbps'), onTap: () => Navigator.pop(ctx, q)),
      const SizedBox(height: 8),
    ])),
  );
  if (quality == null) return;
  try {
    final url = await JioSaavnPlayer.instance.resolveAudioUrl(song, quality);
    final safe = song.title.replaceAll(RegExp(r'[^a-zA-Z0-9 _-]'), '').trim();
    await DownloadService.instance.enqueue(
      url: url,
      title: song.title,
      fileName: '${safe.isEmpty ? 'JioSaavn Song' : safe}_${quality}kbps.mp4',
      headers: const {'User-Agent': 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36', 'Accept': '*/*'},
      isMusic: true,
      artist: song.artist,
      image: song.image,
      duration: song.duration,
      songId: song.id,
    );
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Downloading ${song.title} · $quality kbps')));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
  }
}

Future<void> _playSaavnAndOpen(BuildContext context, List<SaavnSong> songs, {int start = 0}) async {
  if (songs.isEmpty) return;
  try {
    await JioSaavnPlayer.instance.playList(songs, start: start);
    if (context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const SaavnFullPlayer()));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Playback failed: $e')));
  }
}

class MusicPage extends StatefulWidget {
  const MusicPage({super.key});
  @override
  State<MusicPage> createState() => _MusicPageState();
}
class _MusicPageState extends State<MusicPage> {
  final api = JioSaavnPlayer.instance.api;
  late Future<List<SaavnSection>> home;
  final query = TextEditingController();
  bool searching = false, loading = false;
  int tab = 0;
  List<SaavnSong> songs = [];
  List<Map<String,dynamic>> media = [];
  @override
  void initState(){super.initState();home=api.home();}
  @override
  void dispose(){query.dispose();super.dispose();}
  Future<void> search(String q) async {
    if(q.trim().isEmpty)return;
    setState(()=>loading=true);
    try {
      if(tab==0){songs=await api.searchSongs(q);media=[];}
      else {media=await api.searchMedia(['songs','albums','playlists','artists'][tab],q);songs=[];}
    } catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString())));}
    if(mounted)setState(()=>loading=false);
  }
  String img(Map m)=>(m['image']??m['album_image']??'').toString().replaceAll('150x150','500x500').replaceAll('50x50','500x500').replaceAll('http://','https://');
  String type(Map m){final t=(m['type']??m['media_type']??'').toString().toLowerCase();if(t.contains('artist')||m.containsKey('artistid'))return 'artist';if(t.contains('album')||m.containsKey('albumid'))return 'album';if(t.contains('song')||m.containsKey('encrypted_media_url'))return 'song';return 'playlist';}
  Future<void> _searchGenre(String genre) async { setState(() { searching = true; query.text = saavnClean(genre); tab = 0; songs = []; media = []; }); await search(query.text); }
  void open(Map<String,dynamic> m){final t=type(m);if(t=='artist'){Navigator.push(context,MaterialPageRoute(builder:(_)=>SaavnArtistPage(item:m)));}else if(t=='song'){final s=SaavnSong.fromJson(m);play([s],0);}else{showModalBottomSheet<void>(context:context,isScrollControlled:true,showDragHandle:true,builder:(_)=>SaavnTracklistSheet(item:m,playlist:t=='playlist'));}}
  Future<void> play(List<SaavnSong> list,int i)async{try{await JioSaavnPlayer.instance.playList(list,start:i);if(mounted)Navigator.push(context,MaterialPageRoute(builder:(_)=>const SaavnFullPlayer()));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Playback failed: '+e.toString())));}}
  @override
  Widget build(BuildContext context)=>PopScope(canPop: !searching,onPopInvokedWithResult: (didPop, result){if(!didPop && searching){setState(()=>searching=false);}},child:CustomScrollView(slivers:[
    SliverAppBar(floating:true,title:const Text('JioSaavn',style:TextStyle(fontWeight:FontWeight.w800)),actions:[IconButton(onPressed:()=>setState(()=>searching=!searching),icon:const Icon(Icons.search))]),
    if(searching)SliverToBoxAdapter(child:Padding(padding:const EdgeInsets.fromLTRB(16,0,16,12),child:Column(children:[
      TextField(controller:query,textInputAction:TextInputAction.search,onSubmitted:search,decoration:InputDecoration(hintText:'Songs, albums, artists, playlists',suffixIcon:IconButton(onPressed:()=>search(query.text),icon:const Icon(Icons.arrow_forward)),filled:true,border:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide.none))),
      const SizedBox(height:8),SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:List.generate(4,(i)=>Padding(padding:const EdgeInsets.only(right:8),child:ChoiceChip(label:Text(['Songs','Albums','Playlists','Artists'][i]),selected:tab==i,showCheckmark:false,onSelected:(_){setState(()=>tab=i);if(query.text.isNotEmpty)search(query.text);}))))),
    ]))),
    if(loading)const SliverToBoxAdapter(child:LinearProgressIndicator()),
    if(searching&&tab==0)SliverToBoxAdapter(child:Column(children:[for(var i=0;i<songs.length;i++)_songTile(songs[i],songs)])),
    if(searching&&tab!=0)SliverToBoxAdapter(child:Column(children:[for(final m in media)ListTile(leading:ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.network(img(m),width:52,height:52,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.music_note))),title:Text(saavnClean(m['title']??m['name']??'Music')),subtitle:Text(saavnClean(m['subtitle']??m['type']??'')),onTap:()=>open(m))])),
    if(!searching)SliverToBoxAdapter(child:FutureBuilder<List<SaavnSection>>(future:home,builder:(context,snap){
      if(snap.connectionState==ConnectionState.waiting)return const Padding(padding:EdgeInsets.all(32),child:Center(child:CircularProgressIndicator()));
      if(snap.hasError)return Padding(padding:const EdgeInsets.all(20),child:Column(children:[Text('JioSaavn load failed: '+snap.error.toString()),TextButton(onPressed:()=>setState(()=>home=api.home()),child:const Text('Retry'))]));
      final sections = (snap.data??[]).where((s)=>!s.title.toLowerCase().contains('devotional') && !s.title.toLowerCase().contains('bhakti')).toList();
      return Column(children:[for(final sec in sections)_section(sec)]);
    })),
  ]));
  Widget _section(SaavnSection s)=>Padding(padding:const EdgeInsets.only(bottom:20),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Padding(padding:const EdgeInsets.fromLTRB(16,0,16,10),child:Text(s.title,style:Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight:FontWeight.bold))),
    SizedBox(height:188,child:ListView.builder(scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:16),itemCount:s.items.length,itemBuilder:(context,i){final m=s.items[i];final image=img(m);return GestureDetector(onTap:()=>s.title.toLowerCase().contains('genres')? _searchGenre(saavnClean(m['title']??m['name']??'')) : open(m),child:SizedBox(width:136,child:Padding(padding:const EdgeInsets.only(right:12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      ClipRRect(borderRadius:BorderRadius.circular(12),child:AspectRatio(aspectRatio:1,child:image.isEmpty?const ColoredBox(color:Colors.black12,child:Icon(Icons.music_note)):Image.network(image,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.music_note)))),
      const SizedBox(height:7),Text(saavnClean(m['title']??m['name']??'Music'),maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w600,fontSize:13)),
    ]))));})),
  ]));
  Widget _songTile(SaavnSong s,List<SaavnSong> list)=>ListTile(leading:ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.network(s.image,width:50,height:50,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.music_note))),title:Text(s.title,maxLines:1),subtitle:Text(s.artist,maxLines:1),trailing:IconButton(icon:const Icon(Icons.more_vert),onPressed:()=>showModalBottomSheet<void>(context:context,builder:(ctx)=>SafeArea(child:Wrap(children:[
    ListTile(title:Text(s.title),subtitle:Text(s.artist)),
    ListTile(leading:const Icon(Icons.play_arrow),title:const Text('Play next'),onTap:(){final p=JioSaavnPlayer.instance;p.queue.insert((p.index+1).clamp(0,p.queue.length).toInt(),s);Navigator.pop(ctx);}),
    ListTile(leading:const Icon(Icons.queue_music),title:const Text('Add to queue'),onTap:(){JioSaavnPlayer.instance.queue.add(s);Navigator.pop(ctx);}),
    ListTile(leading:const Icon(Icons.download_outlined),title:const Text('Download'),onTap:(){Navigator.pop(ctx);_downloadSaavn(context,s);}),
    ListTile(leading:const Icon(Icons.album),title:const Text('View album'),onTap:(){Navigator.pop(ctx);showModalBottomSheet<void>(context:context,isScrollControlled:true,builder:(_)=>SaavnTracklistSheet(item:{'albumid':s.albumId,'title':s.album,'image':s.image},playlist:false));}),
  ])))),onTap:()=>play(list,list.indexOf(s)));
}

class MusicMiniPlayer extends StatelessWidget {
  const MusicMiniPlayer({super.key});
  @override
  Widget build(BuildContext context){final p=JioSaavnPlayer.instance;return ValueListenableBuilder<int>(valueListenable:p.revision,builder:(context,_,__) {final s=p.current;if(s==null)return const SizedBox.shrink();return Material(color:Theme.of(context).colorScheme.surfaceContainer,child:InkWell(onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const SaavnFullPlayer())),child:SizedBox(height:64,child:Row(children:[
    const SizedBox(width:10),ClipRRect(borderRadius:BorderRadius.circular(7),child:Image.network(s.image,width:46,height:46,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.music_note))),
    const SizedBox(width:10),Expanded(child:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(s.title,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold)),Text(s.artist,maxLines:1,overflow:TextOverflow.ellipsis)])),
    StreamBuilder<PlayerState>(stream:p.audio.playerStateStream,builder:(context,snap)=>IconButton(onPressed:()=>snap.data?.playing==true?p.audio.pause():p.audio.play(),icon:Icon(snap.data?.playing==true?Icons.pause:Icons.play_arrow))),
    IconButton(onPressed:p.next,icon:const Icon(Icons.skip_next)),
    IconButton(tooltip:'Close mini player',onPressed:p.stopAndClear,icon:const Icon(Icons.close)),const SizedBox(width:4),
  ]))));});}
}

class SaavnFullPlayer extends StatefulWidget {
  const SaavnFullPlayer({super.key});
  @override
  State<SaavnFullPlayer> createState()=>_SaavnFullPlayerState();
}
class _SaavnFullPlayerState extends State<SaavnFullPlayer>{
  final p=JioSaavnPlayer.instance;
  bool shuffle=false, repeat=false;
  String time(Duration d)=>d.inMinutes.toString()+':'+(d.inSeconds%60).toString().padLeft(2,'0');
  @override
  Widget build(BuildContext context)=>ValueListenableBuilder<int>(valueListenable:p.revision,builder:(context,_,__){final s=p.current;if(s==null)return const Scaffold(body:Center(child:Text('Nothing playing')));return Scaffold(backgroundColor:const Color(0xFF15171E),appBar:AppBar(backgroundColor:const Color(0xFF15171E),foregroundColor:Colors.white,title:const Text('Playing now'),centerTitle:true,actions:[IconButton(tooltip:'Download',onPressed:()=>_downloadSaavn(context,s),icon:const Icon(Icons.download_outlined)),IconButton(onPressed:_queue,icon:const Icon(Icons.queue_music)),IconButton(onPressed:_lyrics,icon:const Icon(Icons.lyrics_outlined)),PopupMenuButton<String>(onSelected:(v){if(v=='quality')_quality();if(v=='lyrics')_lyrics();},itemBuilder:(_)=>const [PopupMenuItem(value:'quality',child:Text('Audio quality')),PopupMenuItem(value:'lyrics',child:Text('Lyrics'))])]),body:SafeArea(child:Padding(padding:const EdgeInsets.fromLTRB(24,12,24,18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Expanded(flex:6,child:Center(child:AspectRatio(aspectRatio:1,child:ClipRRect(borderRadius:BorderRadius.circular(22),child:Image.network(s.image,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const ColoredBox(color:Colors.black26,child:Icon(Icons.music_note,size:90,color:Colors.white))))))),
    const SizedBox(height:24),Row(children:[Expanded(child:Text(s.title,style:const TextStyle(color:Colors.white,fontSize:28,fontWeight:FontWeight.w700),maxLines:2,overflow:TextOverflow.ellipsis)),IconButton(onPressed:()=>ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Favorite saved in a later music update'))),icon:const Icon(Icons.favorite,color:Color(0xFF7CE8E7),size:30))]),
    Text(s.artist,style:const TextStyle(color:Colors.white60,fontSize:18)),const SizedBox(height:24),
    StreamBuilder<Duration>(stream:p.audio.positionStream,builder:(context,snap){final pos=snap.data??Duration.zero;final total=p.audio.duration??Duration(seconds:s.duration>0?s.duration:1);final max=total.inMilliseconds.toDouble().clamp(1,double.infinity);return Column(children:[
      SliderTheme(data:SliderTheme.of(context).copyWith(activeTrackColor:_musicAccent,inactiveTrackColor:Colors.white54,thumbColor:_musicAccent,trackHeight:2),child:Slider(value:(pos.inMilliseconds/max).clamp(0,1).toDouble(),onChanged:(v)=>p.audio.seek(Duration(milliseconds:(v*max).round())))),
      Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text(time(pos),style:const TextStyle(color:Colors.white38,fontSize:11)),Text(time(total),style:const TextStyle(color:Colors.white38,fontSize:11))]),
    ]);}),
    const Spacer(),Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
      IconButton(color:shuffle?_musicAccent:Colors.white70,onPressed:()async{shuffle=!shuffle;await p.audio.setShuffleModeEnabled(shuffle);if(mounted)setState((){});},icon:const Icon(Icons.shuffle_rounded)),
      IconButton(color:Colors.white,onPressed:p.previous,icon:const Icon(Icons.skip_previous_rounded,size:36)),
      StreamBuilder<PlayerState>(stream:p.audio.playerStateStream,builder:(context,snap)=>Container(width:78,height:78,decoration:const BoxDecoration(color:_musicAccent,shape:BoxShape.circle),child:IconButton(color:const Color(0xFF10252A),iconSize:38,onPressed:()=>snap.data?.playing==true?p.audio.pause():p.audio.play(),icon:Icon(snap.data?.playing==true?Icons.pause_rounded:Icons.play_arrow_rounded)))),
      IconButton(color:Colors.white,onPressed:p.next,icon:const Icon(Icons.skip_next_rounded,size:36)),
      IconButton(color:repeat?_musicAccent:Colors.white70,onPressed:()async{repeat=!repeat;await p.audio.setLoopMode(repeat?LoopMode.one:LoopMode.off);if(mounted)setState((){});},icon:const Icon(Icons.repeat_rounded)),
    ]),const SizedBox(height:10),
  ]))));});
  Future<void> _quality()async{final q=await showDialog<String>(context:context,builder:(ctx)=>SimpleDialog(title:const Text('Audio quality'),children:[for(final v in ['320','160','96'])SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,v),child:Text(v+' kbps'+(p.bitrate==v?' ✓':'')))]));if(q!=null){try{await p.setQuality(q);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString())));}}}
  Future<void> _lyrics()async{final s=p.current;if(s==null)return;showModalBottomSheet<void>(context:context,isScrollControlled:true,showDragHandle:true,builder:(_)=>FutureBuilder<String>(future:p.api.lyrics(s),builder:(ctx,snap)=>SizedBox(height:MediaQuery.sizeOf(ctx).height*.7,child:Padding(padding:const EdgeInsets.all(22),child:snap.connectionState==ConnectionState.waiting?const Center(child:CircularProgressIndicator()):SingleChildScrollView(child:Text(snap.data??'Lyrics unavailable',style:const TextStyle(height:1.7)))))));}
  void _queue(){showModalBottomSheet<void>(context:context,isScrollControlled:true,showDragHandle:true,builder:(ctx)=>SizedBox(height:MediaQuery.sizeOf(ctx).height*.7,child:ListView(children:[const ListTile(title:Text('Up next')),for(var i=0;i<p.queue.length;i++)ListTile(title:Text(p.queue[i].title),subtitle:Text(p.queue[i].artist),selected:i==p.index,onTap:()async{p.index=i;p.revision.value++;await p.playCurrent();if(ctx.mounted)Navigator.pop(ctx);})])));}
}

class SaavnTracklistSheet extends StatefulWidget{
  const SaavnTracklistSheet({super.key,required this.item,required this.playlist});
  final Map<String,dynamic> item;final bool playlist;
  @override State<SaavnTracklistSheet> createState()=>_SaavnTracklistSheetState();
}
class _SaavnTracklistSheetState extends State<SaavnTracklistSheet>{
  late Future<List<SaavnSong>> future;
  @override void initState(){super.initState();final id=(widget.item[widget.playlist?'listid':'albumid']??widget.item['id']??'').toString();future=JioSaavnPlayer.instance.api.albumSongs(id,playlist:widget.playlist);}
  @override Widget build(BuildContext context)=>SafeArea(child:SizedBox(height:MediaQuery.sizeOf(context).height*.82,child:FutureBuilder<List<SaavnSong>>(future:future,builder:(context,snap){final rows=snap.data??[];return Column(children:[
    Padding(padding:const EdgeInsets.all(16),child:Row(children:[ClipRRect(borderRadius:BorderRadius.circular(10),child:Image.network((widget.item['image']??'').toString().replaceAll('150x150','500x500'),width:82,height:82,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.album,size:60))),const SizedBox(width:14),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(saavnClean(widget.item['title']??widget.item['name']??'Music collection'),style:Theme.of(context).textTheme.titleLarge),Text(rows.length.toString()+' songs')]))])),
    Row(children:[const SizedBox(width:16),FilledButton.icon(onPressed:rows.isEmpty?null:()=>_playSaavnAndOpen(context,rows),icon:const Icon(Icons.play_arrow),label:const Text('Play all')),const SizedBox(width:8),OutlinedButton.icon(onPressed:rows.isEmpty?null:(){final shuffled=[...rows]..shuffle();_playSaavnAndOpen(context,shuffled);},icon:const Icon(Icons.shuffle),label:const Text('Shuffle'))]),
    if(snap.connectionState==ConnectionState.waiting)const Expanded(child:Center(child:CircularProgressIndicator()))else if(snap.hasError)Expanded(child:Center(child:Text('Tracklist failed: '+snap.error.toString())))else Expanded(child:ListView.builder(itemCount:rows.length,itemBuilder:(context,i)=>ListTile(leading:Text((i+1).toString()),title:Text(rows[i].title),subtitle:Text(rows[i].artist),onTap:()=>_playSaavnAndOpen(context,rows,start:i),trailing:PopupMenuButton<String>(onSelected:(v){if(v=='download')_downloadSaavn(context,rows[i]);},itemBuilder:(_)=>const [PopupMenuItem(value:'download',child:Text('Download'))])))),
  ]);})));
}
class SaavnArtistPage extends StatefulWidget{
  const SaavnArtistPage({super.key,required this.item});final Map<String,dynamic> item;
  @override State<SaavnArtistPage> createState()=>_SaavnArtistPageState();
}
class _SaavnArtistPageState extends State<SaavnArtistPage>{
  late Future<dynamic> future;
  @override void initState(){super.initState();future=JioSaavnPlayer.instance.api.call('artist.getArtistPageDetails',{'artistId':(widget.item['artistid']??widget.item['id']??'').toString(),'n_song':'50','n_album':'50'});}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text(saavnClean(widget.item['name']??widget.item['title']??'Artist'))),body:FutureBuilder<dynamic>(future:future,builder:(context,snap){
    if(snap.connectionState==ConnectionState.waiting)return const Center(child:CircularProgressIndicator());if(snap.hasError)return Center(child:Text(snap.error.toString()));
    final d=snap.data is Map?snap.data as Map:{};final t=d['topSongs'];final raw=t is Map?t['songs']:t;final songs=raw is List?raw.whereType<Map>().map((e)=>SaavnSong.fromJson(e)).toList():<SaavnSong>[];final a=d['topAlbums'];final albums=a is Map?a['albums']:a;
    return ListView(children:[
      Padding(padding:const EdgeInsets.all(22),child:Column(children:[CircleAvatar(radius:58,backgroundImage:NetworkImage((widget.item['image']??'').toString().replaceAll('150x150','500x500'))),const SizedBox(height:12),Text(saavnClean(widget.item['name']??widget.item['title']),style:Theme.of(context).textTheme.headlineSmall),Text((widget.item['follower_count']??widget.item['fan_count']??'').toString()+' Fans'),FilledButton.icon(onPressed:songs.isEmpty?null:()=>_playSaavnAndOpen(context,songs),icon:const Icon(Icons.play_arrow),label:const Text('Play all'))])),
      const Padding(padding:EdgeInsets.all(16),child:Text('Top Songs',style:TextStyle(fontWeight:FontWeight.bold,fontSize:19))),
      for(final s in songs)ListTile(title:Text(s.title),subtitle:Text(s.artist),onTap:()=>_playSaavnAndOpen(context,songs,start:songs.indexOf(s))),
      const Padding(padding:EdgeInsets.all(16),child:Text('Top Albums',style:TextStyle(fontWeight:FontWeight.bold,fontSize:19))),
      if(albums is List)for(final item in albums.whereType<Map>())ListTile(title:Text(saavnClean(item['title']??item['name'])),subtitle:const Text('Album'),onTap:()=>showModalBottomSheet<void>(context:context,isScrollControlled:true,showDragHandle:true,builder:(_)=>SaavnTracklistSheet(item:Map<String,dynamic>.from(item),playlist:false))),
    ]);
  }));
}
