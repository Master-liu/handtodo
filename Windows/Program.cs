using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Windows.Interop;
using Forms = System.Windows.Forms;
using WpfImage = System.Windows.Controls.Image;
using Point = System.Windows.Point;
using Color = System.Windows.Media.Color;

namespace HandTodoWindows;
public sealed class P { public double X{get;set;} public double Y{get;set;} public P(){} public P(Point p){X=p.X;Y=p.Y;} public Point Point=>new(X,Y); }
public sealed class Note {public string Text{get;set;}="";public double X{get;set;}public double Y{get;set;}public double Width{get;set;}public double Height{get;set;}public byte[] Ink{get;set;}=[];public bool Done{get;set;}public double Distance{get;set;}public int Reversals{get;set;} }
public sealed class Stroke {public string Color{get;set;}="#202020";public List<P?> Points{get;set;}=[];}
public sealed class Sticker {public string Asset{get;set;}="";public double X{get;set;}=245;public double Y{get;set;}=265;public double Scale{get;set;}=1;public double Rotation{get;set;} }
public sealed class HandState {public List<Note> Notes{get;set;}=[];public List<Stroke> Strokes{get;set;}=[];public List<Sticker> Stickers{get;set;}=[];public bool Empty=>Notes.Count+Strokes.Count+Stickers.Count==0;}
public static class Program {
 [STAThread] public static void Main(string[] args){
  using var mutex=new System.Threading.Mutex(true,args.Contains("--self-test") ? "Local\\HandTodo.Windows.Tests" : "Local\\HandTodo.Windows.SingleInstance",out var first);if(!first)return;
  bool test=args.Contains("--self-test");string output=args.Length>1?Path.GetFullPath(args[1]):Path.Combine(AppContext.BaseDirectory,"self-test");
  string temporary=Path.Combine(Path.GetTempPath(),"HandTodo-test-"+Guid.NewGuid());
  try {
   var app=new System.Windows.Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
   var window=new HandWindow(test?temporary:null);
   if(test)window.Loaded+=(s,e)=>window.Dispatcher.BeginInvoke(new Action(()=>{
    Directory.CreateDirectory(output);
    try{window.SelfTest(output);File.WriteAllText(Path.Combine(output,"result.txt"),"PASS: native window startup, application and tray icons, embedded assets, text, smudge undo, drawing, sticker transforms, persistence, height mapping, wash and zero residue");window.Close();}
    catch(Exception failure){File.WriteAllText(Path.Combine(output,"result.txt"),failure.ToString());Environment.ExitCode=1;window.Close();}
   }));
   app.Run(window);
  } catch(Exception e){if(test){Directory.CreateDirectory(output);File.WriteAllText(Path.Combine(output,"result.txt"),e.ToString());Environment.ExitCode=1;}else Forms.MessageBox.Show("掌上待办未能启动：\n"+e.Message,"掌上待办");}
  finally{if(test&&Directory.Exists(temporary))Directory.Delete(temporary,true);}
 }
}
public sealed class HandWindow:Window {
 const int W=640,H=427; readonly Canvas canvas=new(){Width=W,Height=H,Background=Brushes.Transparent,Focusable=true};
 readonly WpfImage handImage=new(){Width=W,Height=H,IsHitTestVisible=false},inkImage=new(){Width=W,Height=H,IsHitTestVisible=false};
 readonly Forms.NotifyIcon tray; readonly DispatcherTimer timer; readonly string folder; readonly byte[] skin=new byte[W*H];readonly double[] heights=new double[W*H];readonly double[] sourceX=new double[W*H],sourceY=new double[W*H];
 readonly System.Drawing.Icon applicationIcon;
 readonly Dictionary<string,BitmapSource> assets=[];readonly List<byte[]> history=[];HandState state=new();TextBox? editor;Point editorAnchor;
 enum Tool{Todo,Pen,Sticker} Tool tool; string pen="#202020";int selected=-1;Point? down,last;long downTime;bool moved,held,recorded,edge,menuOpen;int active=-1,direction; bool altMove;
 readonly Typeface handwriting=new(new FontFamily("KaiTi, Segoe Print, Microsoft YaHei UI"),FontStyles.Normal,FontWeights.Normal,FontStretches.Normal);
 static readonly(string id,string title)[] Catalog=[("01-cat","趴线小猫"),("02-rocket","迷你火箭"),("03-ufo","飞碟捞星星"),("04-boat","漂流纸船"),("05-coffee","跑步咖啡杯")];
 [StructLayout(LayoutKind.Sequential)]struct XY{public int X,Y;}
 [DllImport("user32.dll")]static extern bool GetCursorPos(out XY p);
 [DllImport("user32.dll")]static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
 protected override void OnSourceInitialized(EventArgs e){base.OnSourceInitialized(e);var src=(HwndSource)PresentationSource.FromVisual(this);src.AddHook(HitHook);}
 IntPtr HitHook(IntPtr hwnd,int msg,IntPtr wp,IntPtr lp,ref bool handled){if(msg==0x84&&!held&&!menuOpen){GetCursorPos(out var c);var p=PointFromScreen(new Point(c.X,c.Y));if(!Skin(p)&&!new Rect(26,296,52,30).Contains(p)){handled=true;return new IntPtr(-1);}}return IntPtr.Zero;}
 public HandWindow(string? dataFolder=null){
  folder=dataFolder??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"HandTodo");Directory.CreateDirectory(folder);
  try{if(File.Exists(DataFile))state=Decode(File.ReadAllBytes(DataFile));}catch{File.Copy(DataFile,Path.Combine(folder,"state-recovery-"+DateTime.Now.ToString("yyyyMMddHHmmss")+".gz"),true);}
  Width=W;Height=H;WindowStyle=WindowStyle.None;AllowsTransparency=true;Background=Brushes.Transparent;ShowInTaskbar=false;Topmost=true;ResizeMode=ResizeMode.NoResize;Title="掌上待办";Content=canvas;
  Icon=Resource("app-icon.png");
  using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("HandTodo.ico")??throw new FileNotFoundException("HandTodo.ico")){
   using var icon=new System.Drawing.Icon(stream);applicationIcon=(System.Drawing.Icon)icon.Clone();
  }
  var hand=Resource("hand.png");handImage.Source=hand;canvas.Children.Add(handImage);canvas.Children.Add(inkImage);
  var normalized=Render(g=>g.DrawImage(hand,new Rect(0,0,W,H)));var pixels=Pixels(normalized);
  var map=Render(g=>g.DrawImage(Resource("hand-height.png"),new Rect(0,0,W,H)));var hp=Pixels(map);
  for(int i=0;i<W*H;i++){skin[i]=pixels[i*4+3];heights[i]=hp[i*4]/255.0;}
  for(int y=0;y<H;y++)for(int x=0;x<W;x++){var p=Canonical(new Point(x,y));sourceX[y*W+x]=p.X;sourceY[y*W+x]=p.Y;}
  foreach(var (id,_) in Catalog)assets[id]=Resource(id+".png");
  state.Notes.RemoveAll(n=>n.Ink.Length!=W*H*4);state.Stickers.RemoveAll(s=>!assets.ContainsKey(s.Asset));
  var wrist=new TextBlock{Text="涂鸦",FontFamily=handwriting.FontFamily,FontSize=18,Foreground=Brushes.SaddleBrown,Width=52,Height=30,TextAlignment=TextAlignment.Center,Cursor=Cursors.Hand,RenderTransform=new RotateTransform(-5,26,15)};
  Canvas.SetLeft(wrist,26);Canvas.SetTop(wrist,296);canvas.Children.Add(wrist);wrist.MouseLeftButtonDown+=(s,e)=>e.Handled=true;wrist.MouseLeftButtonUp+=(s,e)=>{OpenTools(wrist);e.Handled=true;};
  canvas.MouseLeftButtonDown+=Press;canvas.MouseMove+=Drag;canvas.MouseLeftButtonUp+=Release;canvas.MouseRightButtonUp+=RightClick;canvas.MouseWheel+=Wheel;PreviewKeyDown+=Keys;
  tray=new Forms.NotifyIcon{Icon=applicationIcon,Text="掌上待办",Visible=true};var tm=new Forms.ContextMenuStrip();tm.Opened+=(s,e)=>menuOpen=true;tm.Closed+=(s,e)=>menuOpen=false;
  tm.Items.Add("伸出手",null,(s,e)=>Reveal());tm.Items.Add("工具与洗手",null,(s,e)=>{Reveal();OpenTools(wrist);});tm.Items.Add("退出",null,(s,e)=>Close());tray.ContextMenuStrip=tm;tray.DoubleClick+=(s,e)=>Reveal();
  timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(30)};timer.Tick+=(s,e)=>Tick();timer.Start();Loaded+=(s,e)=>{Refresh();Reveal();};Closed+=(s,e)=>{Commit();Save();timer.Stop();tray.Dispose();applicationIcon.Dispose();System.Windows.Application.Current.Shutdown();};
 }
 string DataFile=>Path.Combine(folder,"state.json.gz");
 static BitmapSource Resource(string name){using var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream(name)??throw new FileNotFoundException(name);var b=new BitmapImage();b.BeginInit();b.CacheOption=BitmapCacheOption.OnLoad;b.StreamSource=stream;b.EndInit();b.Freeze();return b;}
 static BitmapSource Render(Action<DrawingContext> paint){var v=new DrawingVisual();using(var dc=v.RenderOpen())paint(dc);var b=new RenderTargetBitmap(W,H,96,96,PixelFormats.Pbgra32);b.Render(v);b.Freeze();return b;}
 static byte[] Pixels(BitmapSource b){var fmt=new FormatConvertedBitmap(b,PixelFormats.Pbgra32,null,0);var bytes=new byte[W*H*4];fmt.CopyPixels(bytes,W*4,0);return bytes;}
 static BitmapSource Image(byte[] bytes){var b=BitmapSource.Create(W,H,96,96,PixelFormats.Pbgra32,null,bytes,W*4);b.Freeze();return b;}
 double HeightAt(Point p){var x=Math.Clamp(p.X,0,W-1);var y=Math.Clamp(p.Y,0,H-1);int ix=(int)x,iy=(int)y;double fx=x-ix,fy=y-iy;double V(int dx,int dy)=>heights[Math.Min(H-1,iy+dy)*W+Math.Min(W-1,ix+dx)];return V(0,0)*(1-fx)*(1-fy)+V(1,0)*fx*(1-fy)+V(0,1)*(1-fx)*fy+V(1,1)*fx*fy;}
 Point Display(Point p){var gradient=(HeightAt(new(p.X+2,p.Y))-HeightAt(new(p.X-2,p.Y)))/4;return new(p.X-gradient*70,p.Y-HeightAt(p)*18);}
 Point Canonical(Point p){var q=p;for(int i=0;i<10;i++){var a=Display(q);q=new(q.X+p.X-a.X,q.Y+p.Y-a.Y);}return q;}
 bool Skin(Point p)=>p.X>=0&&p.Y>=0&&p.X<W&&p.Y<H&&skin[(int)p.Y*W+(int)p.X]>240;
 static double Angle(Point p){if(p.Y<164&&p.X>170&&p.X<345)return Math.Atan2(-116,88);if(p.X<=360)return 0;double distance=double.MaxValue,angle=0;foreach(var a in new[]{(355d,182d,540d,135d),(380d,240d,590d,207d),(380d,300d,580d,288d),(370d,360d,515d,385d)}){var dx=a.Item3-a.Item1;var dy=a.Item4-a.Item2;var t=Math.Clamp(((p.X-a.Item1)*dx+(p.Y-a.Item2)*dy)/(dx*dx+dy*dy),0,1);var d=double.Hypot(p.X-a.Item1-t*dx,p.Y-a.Item2-t*dy);if(d<distance){distance=d;angle=Math.Atan2(dy,dx);}}return angle;}
 static Point Rotate(Point p,Point anchor,double angle){var x=p.X-anchor.X;var y=p.Y-anchor.Y;return new(anchor.X+x*Math.Cos(angle)-y*Math.Sin(angle),anchor.Y+x*Math.Sin(angle)+y*Math.Cos(angle));}
 static Point Anchor(Note n)=>new(n.X,n.Y);Point NotePoint(Point p,Note n)=>Rotate(p,Anchor(n),-Angle(Anchor(n)));
 byte[] Warp(byte[] input){var output=new byte[input.Length];for(int i=0;i<W*H;i++){double x=sourceX[i],y=sourceY[i];if(skin[i]<240||x<0||y<0||x>=W-1||y>=H-1)continue;int ix=(int)x,iy=(int)y,o=(iy*W+ix)*4;double fx=x-ix,fy=y-iy;for(int c=0;c<4;c++)output[i*4+c]=(byte)Math.Clamp((int)Math.Round(input[o+c]*(1-fx)*(1-fy)+input[o+4+c]*fx*(1-fy)+input[o+W*4+c]*(1-fx)*fy+input[o+W*4+4+c]*fx*fy),0,255);}return output;}
 void Refresh(){var image=Render(g=>{
  foreach(var n in state.Notes){g.PushTransform(new RotateTransform(Angle(Anchor(n))*180/Math.PI,n.X,n.Y));g.DrawImage(Image(n.Ink),new Rect(0,0,W,H));g.Pop();}
  foreach(var stroke in state.Strokes){var brush=(Brush)new BrushConverter().ConvertFromString(stroke.Color)!;var pen=new Pen(brush,2.2){StartLineCap=PenLineCap.Round,EndLineCap=PenLineCap.Round,LineJoin=PenLineJoin.Round};Point? lastPoint=null;foreach(var p in stroke.Points){if(p==null){lastPoint=null;continue;}if(lastPoint is Point before)g.DrawLine(pen,before,p.Point);else g.DrawEllipse(brush,null,p.Point,1.1,1.1);lastPoint=p.Point;}}
  foreach(var s in state.Stickers){var asset=assets[s.Asset];g.PushTransform(new RotateTransform(s.Rotation*180/Math.PI,s.X,s.Y));var width=100*s.Scale;var height=width*asset.PixelHeight/asset.PixelWidth;g.DrawImage(asset,new Rect(s.X-width/2,s.Y-height/2,width,height));g.Pop();}
 });inkImage.Source=Image(Warp(Pixels(image)));}
 static byte[] Encode(HandState s){using var output=new MemoryStream();using(var gz=new GZipStream(output,CompressionLevel.Fastest,true))JsonSerializer.Serialize(gz,s);return output.ToArray();}
 static HandState Decode(byte[] b){using var input=new MemoryStream(b);using var gz=new GZipStream(input,CompressionMode.Decompress);return JsonSerializer.Deserialize<HandState>(gz)??new();}
 static void AtomicWrite(string path,byte[] bytes){File.WriteAllBytes(path+".tmp",bytes);File.Move(path+".tmp",path,true);}
 void Save(){AtomicWrite(DataFile,Encode(state));}
 void Snapshot(){history.Add(Encode(state));if(history.Count>30)history.RemoveAt(0);}
 void Undo(){Commit();if(history.Count>0){state=Decode(history[^1]);history.RemoveAt(history.Count-1);selected=-1;Refresh();Save();}else if(state.Empty&&File.Exists(Path.Combine(folder,"wash-backup.gz"))){state=Decode(File.ReadAllBytes(Path.Combine(folder,"wash-backup.gz")));Refresh();Save();}}
 FormattedText Text(string value,double width)=>new(value,System.Globalization.CultureInfo.GetCultureInfo("zh-CN"),FlowDirection.LeftToRight,handwriting,16,new SolidColorBrush(Color.FromRgb(61,48,102)),1){MaxTextWidth=width,TextAlignment=TextAlignment.Left};
 void BeginInput(Point p){
  double angle=Angle(p);Point anchor=new(p.X+Math.Sin(angle)*8,p.Y-Math.Cos(angle)*8);double width=190;
  for(double offset=4;offset<=190;offset+=2){if(!Skin(Display(Rotate(new(anchor.X+offset,anchor.Y+3),anchor,angle)))||!Skin(Display(Rotate(new(anchor.X+offset,anchor.Y+20),anchor,angle)))){width=offset-2;break;}}
  if(width<26)return;editorAnchor=anchor;editor=new TextBox{Width=width,MinHeight=24,MaxHeight=Math.Max(24,H-anchor.Y),AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,Background=Brushes.Transparent,BorderThickness=new Thickness(0),Padding=new Thickness(0),Foreground=new SolidColorBrush(Color.FromRgb(61,48,102)),FontFamily=handwriting.FontFamily,FontSize=16,CaretBrush=Brushes.DarkSlateBlue,RenderTransform=new RotateTransform(angle*180/Math.PI)};
  var location=Display(anchor);Canvas.SetLeft(editor,location.X);Canvas.SetTop(editor,location.Y);canvas.Children.Add(editor);Activate();editor.Focus();Keyboard.Focus(editor);
 }
 void Commit(){if(editor==null)return;var input=editor;editor=null;canvas.Children.Remove(input);var text=input.Text.Trim();if(text.Length==0)return;Snapshot();var formatted=Text(text,input.Width);var n=new Note{Text=text,X=editorAnchor.X,Y=editorAnchor.Y,Width=Math.Min(input.Width,formatted.WidthIncludingTrailingWhitespace+2),Height=formatted.Height+2};n.Ink=Pixels(Render(g=>g.DrawText(formatted,Anchor(n))));state.Notes.Add(n);Refresh();Save();}
 int HitNote(Point p,bool nearby=false){for(int i=state.Notes.Count-1;i>=0;i--){var n=state.Notes[i];if(n.Done)continue;var q=NotePoint(p,n);double margin=nearby?20:4;if(new Rect(n.X-margin,n.Y-margin,n.Width+2*margin,n.Height+2*margin).Contains(q))return i;}return -1;}
 int HitSticker(Point p){for(int i=state.Stickers.Count-1;i>=0;i--){var s=state.Stickers[i];var q=Rotate(p,new(s.X,s.Y),-s.Rotation);var width=100*s.Scale;var height=width*assets[s.Asset].PixelHeight/assets[s.Asset].PixelWidth;if(new Rect(s.X-width/2,s.Y-height/2,width,height).Contains(q))return i;}return -1;}
 void Press(object sender,MouseButtonEventArgs e){if(e.OriginalSource is TextBox)return;var raw=e.GetPosition(canvas);if(!Skin(raw))return;Commit();Activate();canvas.Focus();held=true;recorded=false;moved=false;down=Canonical(raw);last=down;downTime=Stopwatch.GetTimestamp();altMove=Keyboard.Modifiers.HasFlag(ModifierKeys.Alt);active=-1;direction=0;canvas.CaptureMouse();
  if(tool==Tool.Pen){Snapshot();recorded=true;state.Strokes.Add(new Stroke{Color=pen,Points=[new P(down.Value)]});Refresh();}
  else if(tool==Tool.Sticker)selected=HitSticker(down.Value);
  else {active=HitNote(down.Value);if(active>=0&&!altMove)last=NotePoint(down.Value,state.Notes[active]);}
  e.Handled=true;
 }
 void Drag(object sender,MouseEventArgs e){if(!held||down==null)return;var raw=e.GetPosition(canvas);var p=Canonical(raw);if(double.Hypot(p.X-down.Value.X,p.Y-down.Value.Y)>4)moved=true;
  if(tool==Tool.Pen){state.Strokes[^1].Points.Add(Skin(raw)?new P(p):null);Refresh();return;}
  if(tool==Tool.Sticker){if(selected>=0&&last is Point before&&Skin(raw)){if(!recorded){Snapshot();recorded=true;}state.Stickers[selected].X+=p.X-before.X;state.Stickers[selected].Y+=p.Y-before.Y;last=p;Refresh();}return;}
  if(active<0&&moved){active=HitNote(p,true);if(active>=0)last=altMove?p:NotePoint(p,state.Notes[active]);}
  if(active<0||last==null)return;var n=state.Notes[active];var current=altMove?p:NotePoint(p,n);double dx=current.X-last.Value.X,dy=current.Y-last.Value.Y,length=double.Hypot(dx,dy);if(length<0.5)return;if(!recorded){Snapshot();recorded=true;}
  if(altMove){if(Skin(raw)){var shifted=new byte[W*H*4];int ix=(int)Math.Round(dx),iy=(int)Math.Round(dy);for(int y=0;y<H;y++)for(int x=0;x<W;x++){int nx=x+ix,ny=y+iy;if(nx>=0&&nx<W&&ny>=0&&ny<H)Buffer.BlockCopy(n.Ink,(y*W+x)*4,shifted,(ny*W+nx)*4,4);}n.Ink=shifted;n.X+=ix;n.Y+=iy;last=new Point(last.Value.X+ix,last.Value.Y+iy);}}
  else if(new Rect(n.X-24,n.Y-24,n.Width+48,n.Height+48).Contains(current)){
   int sign=Math.Abs(dx)>Math.Abs(dy)?Math.Sign(dx):Math.Sign(dy);if(direction!=0&&direction!=sign&&length>2)n.Reversals++;if(length>2)direction=sign;n.Distance+=Math.Min(length,30);
   int steps=Math.Clamp((int)(length/3),1,100);for(int k=1;k<=steps;k++)Smudge(n,new(last.Value.X+dx*k/steps,last.Value.Y+dy*k/steps),dx/steps,dy/steps);
   if(n.Distance>Math.Max(240,n.Width*3)&&n.Reversals>=3)n.Done=true;last=current;
  }Refresh();
 }
 void Smudge(Note n,Point p,double dx,double dy){var copy=(byte[])n.Ink.Clone();for(int y=Math.Max(0,(int)p.Y-23);y<=Math.Min(H-1,(int)p.Y+23);y++)for(int x=Math.Max(0,(int)p.X-23);x<=Math.Min(W-1,(int)p.X+23);x++){double d=double.Hypot(x-p.X,y-p.Y);if(d>=23)continue;int sx=Math.Clamp(x-(int)Math.Round(dx*2),0,W-1),sy=Math.Clamp(y-(int)Math.Round(dy*2),0,H-1);double t=(1-d/23)*0.72;for(int c=0;c<4;c++)n.Ink[(y*W+x)*4+c]=(byte)Math.Clamp((int)Math.Round(copy[(y*W+x)*4+c]*(1-t)+copy[(sy*W+sx)*4+c]*t),0,255);}}
 void Release(object sender,MouseButtonEventArgs e){if(!held)return;var p=down;bool click=tool==Tool.Todo&&active<0&&!moved&&Stopwatch.GetElapsedTime(downTime).TotalMilliseconds<350&&Skin(e.GetPosition(canvas));held=false;down=last=null;active=-1;canvas.ReleaseMouseCapture();Save();if(click&&p is Point point)BeginInput(point);e.Handled=true;}
 void TransformSticker(double factor,double angle){if(selected<0||selected>=state.Stickers.Count)return;Snapshot();var s=state.Stickers[selected];s.Scale=Math.Clamp(s.Scale*factor,0.25,3);s.Rotation=(s.Rotation+angle)%(2*Math.PI);Refresh();Save();}
 void Wheel(object sender,MouseWheelEventArgs e){if(tool!=Tool.Sticker)return;var hit=HitSticker(Canonical(e.GetPosition(canvas)));if(hit>=0)selected=hit;if(Keyboard.Modifiers.HasFlag(ModifierKeys.Alt))TransformSticker(1,e.Delta/120.0*Math.PI/12);else TransformSticker(Math.Pow(1.12,e.Delta/120.0),0);e.Handled=true;}
 void RemoveSticker(){if(selected<0||selected>=state.Stickers.Count)return;Snapshot();state.Stickers.RemoveAt(selected);selected=-1;Refresh();Save();}
 void RightClick(object sender,MouseButtonEventArgs e){if(tool!=Tool.Sticker)return;selected=HitSticker(Canonical(e.GetPosition(canvas)));if(selected<0)return;var m=NewMenu();Add(m,"放大",()=>TransformSticker(1.15,0));Add(m,"缩小",()=>TransformSticker(1/1.15,0));Add(m,"向左旋转 15°",()=>TransformSticker(1,-Math.PI/12));Add(m,"向右旋转 15°",()=>TransformSticker(1,Math.PI/12));Add(m,"删除图案",RemoveSticker);m.IsOpen=true;}
 void Keys(object sender,KeyEventArgs e){if(editor!=null){if(e.Key==Key.Enter&&!Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)){Commit();e.Handled=true;}else if(e.Key==Key.Escape){canvas.Children.Remove(editor);editor=null;e.Handled=true;}return;}if(Keyboard.Modifiers.HasFlag(ModifierKeys.Control)&&e.Key==Key.Z){Undo();e.Handled=true;}else if(tool==Tool.Sticker&&(e.Key==Key.Delete||e.Key==Key.Back)){RemoveSticker();e.Handled=true;}}
 ContextMenu NewMenu(){var m=new ContextMenu();m.Opened+=(s,e)=>menuOpen=true;m.Closed+=(s,e)=>menuOpen=false;return m;}
 static void Add(ContextMenu menu,string title,Action action){var item=new MenuItem{Header=title};item.Click+=(s,e)=>action();menu.Items.Add(item);}
 void SetTool(Tool mode){Commit();tool=mode;selected=-1;}
 void OpenTools(FrameworkElement target){Commit();var m=NewMenu();m.PlacementTarget=target;Add(m,"待办模式",()=>SetTool(Tool.Todo));Add(m,"黑色画笔",()=>{SetTool(Tool.Pen);pen="#202020";});Add(m,"红色画笔",()=>{SetTool(Tool.Pen);pen="#D1292E";});Add(m,"蓝色画笔",()=>{SetTool(Tool.Pen);pen="#2047B3";});Add(m,"图案模式",()=>SetTool(Tool.Sticker));foreach(var (id,title) in Catalog)Add(m,"添加图案 · "+title,()=>{SetTool(Tool.Sticker);Snapshot();state.Stickers.Add(new Sticker{Asset=id});selected=state.Stickers.Count-1;Refresh();Save();});m.Items.Add(new Separator());Add(m,"撤销 (Ctrl+Z)",Undo);Add(m,"清空涂画",()=>{Snapshot();state.Strokes.Clear();Refresh();Save();});Add(m,"洗手 · 清除所有内容",Wash);Add(m,"撤销洗手",()=>{if(state.Empty&&File.Exists(Path.Combine(folder,"wash-backup.gz"))){state=Decode(File.ReadAllBytes(Path.Combine(folder,"wash-backup.gz")));Refresh();Save();}});m.IsOpen=true;}
 void Wash(){Commit();if(state.Empty)return;var backup=Encode(state);AtomicWrite(Path.Combine(folder,"wash-backup.gz"),backup);Snapshot();state=new();selected=-1;Refresh();Save();}
 public void SelfTest(string output){
  static void Check(bool condition,string description){if(!condition)throw new InvalidOperationException(description);}
  Check(IsVisible&&canvas.Children.Count==3,"Native window and wrist tool must initialize");Check(assets.Count==5,"All five doodles must be embedded");Check(Skin(new Point(210,240)),"Palm must accept input");
  Check(Icon is BitmapSource icon&&icon.PixelWidth==256&&tray.Icon==applicationIcon,"Application and tray must use the hi hand logo");
  foreach(var p in new[]{new Point(210,240),new Point(250,110),new Point(430,175)}){var q=Canonical(Display(p));Check(double.Hypot(p.X-q.X,p.Y-q.Y)<0.1,"Height-map coordinates must round trip");}
  BeginInput(new Point(210,240));Check(editor!=null,"Click input must create native editor");editor!.Text="下午交稿\n拿快递";Commit();Check(state.Notes.Count==1&&state.Notes[0].Height>30,"Multiline text must commit");
  var original=(byte[])state.Notes[0].Ink.Clone();Snapshot();Smudge(state.Notes[0],new Point(230,250),6,0);state.Notes[0].Done=true;Undo();Check(!state.Notes[0].Done&&original.SequenceEqual(state.Notes[0].Ink),"Undo must restore original ink and task state");
  state.Strokes.Add(new Stroke{Color="#D1292E",Points=[new P(new Point(210,300)),new P(new Point(260,305))]});
  state.Stickers.Add(new Sticker{Asset="02-rocket",X=280,Y=280});tool=Tool.Sticker;selected=0;TransformSticker(1.5,Math.PI/4);Check(Math.Abs(state.Stickers[0].Scale-1.5)<0.001&&Math.Abs(state.Stickers[0].Rotation-Math.PI/4)<0.001,"Sticker scale and angle must work");
  Save();var restored=Decode(File.ReadAllBytes(DataFile));Check(restored.Notes.Count==1&&restored.Strokes.Count==1&&restored.Stickers.Count==1,"Independent layers must survive saving");
  Refresh();var rendered=Pixels((BitmapSource)inkImage.Source);Check(rendered.Any(v=>v>0),"Ink must be visible");for(int i=0;i<W*H;i++)if(skin[i]<240)Check(rendered[i*4+3]==0,"Ink must remain inside skin");
  canvas.UpdateLayout();Dispatcher.Invoke(()=>{},DispatcherPriority.ApplicationIdle);
  var screenshot=new RenderTargetBitmap(W,H,96,96,PixelFormats.Pbgra32);screenshot.Render(canvas);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(screenshot));using(var file=File.Create(Path.Combine(output,"windows-preview.png")))encoder.Save(file);
  Wash();Check(state.Empty&&Pixels((BitmapSource)inkImage.Source).All(v=>v==0),"Wash must remove every pixel of every content layer");Check(Decode(File.ReadAllBytes(DataFile)).Empty,"Clean hand must persist");Undo();Check(state.Notes.Count==1&&state.Strokes.Count==1&&state.Stickers.Count==1,"Undo wash must restore all layer types");
 }
 void Reveal(){var cursor=Forms.Cursor.Position;var screen=Forms.Screen.FromPoint(cursor);Show();var dpi=VisualTreeHelper.GetDpi(this);int height=(int)(H*dpi.DpiScaleY),width=(int)(W*dpi.DpiScaleX);SetWindowPos(new WindowInteropHelper(this).Handle,new IntPtr(-1),screen.Bounds.Left,screen.WorkingArea.Top+(screen.WorkingArea.Height-height)/2,width,height,0x0010);}
 void Tick(){GetCursorPos(out var p);bool atEdge=Forms.Screen.AllScreens.Any(s=>p.X>=s.Bounds.Left&&p.X<=s.Bounds.Left+3&&p.Y>s.WorkingArea.Top+30&&p.Y<s.WorkingArea.Bottom-30);bool entered=atEdge&&!edge;edge=atEdge;if(!IsVisible){if(entered)Reveal();return;}if(held||menuOpen)return;var local=PointFromScreen(new Point(p.X,p.Y));if(atEdge||new Rect(0,0,W,H).Contains(local))return;Commit();Hide();}
}
