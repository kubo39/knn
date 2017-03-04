# perf k-NN

[以前書いたもの](http://kubo39.hatenablog.com/entry/2015/11/04/k-NN_in_D%2C_with_parallelism)はシングルスレッド版のRust/OCamlよりも遅かった。これをprofilingしてみる。

- スペック

```
$ lscpu                                                [kubo39:knn][git:master]
Architecture:          x86_64
CPU 操作モード:   32-bit, 64-bit
Byte Order:            Little Endian
CPU(s):                4
On-line CPU(s) list:   0-3
コアあたりのスレッド数:2
ソケットあたりのコア数:2
Socket(s):             1
NUMA ノード数:     1
ベンダー ID:       GenuineIntel
CPU ファミリー:   6
モデル:             69
Model name:            Intel(R) Core(TM) i5-4200U CPU @ 1.60GHz
...
```

- dmdのバージョン

```console
$ dmd --version                                        [kubo39:knn][git:master]
DMD64 D Compiler v2.073.1
```

コードを2.073.1でも動くように修正。

```d
import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.stdio;
import std.string;
import std.typecons;
import std.parallelism;

struct LabelPixel
{
    int label;
    int[] pixels;
}

auto slurpFile(string filename)
{
    int count;

    auto lp = File(filename)
        .byLine
        .dropOne
        .tee!(a => count++)
        .map!chomp
        .map!(a => a.to!string.split(","))
        .map!(a => LabelPixel(a[0].to!int, a[1..$].to!(int[])) )
        .array;
    return tuple(lp, count);
}

int distanceSqrt(const ref int[] x, const ref int[] y) pure
{
    return reduce!((a, b) => a + (b[0] - b[1]) * (b[0] - b[1]))(0, x.zip(y));
}

int classify(const ref LabelPixel[] training, const ref int[] pixels) pure
{
    int smallest = int.max;
    int result = void;

    foreach (t; training)
    {
        int tmp = distanceSqrt(t.pixels, pixels);
        if (tmp < smallest)
        {
            smallest = tmp;
            result = t.label;
        }
    }
    return result;
}

void main()
{
    const trainingSet = "trainingsample.csv".slurpFile;
    const validationSample = "validationsample.csv".slurpFile;

    int count(const LabelPixel data) pure
    {
        int num;
        if (classify(trainingSet[0], data.pixels) == data.label)
            num++;
        return num;
    }

    immutable num = taskPool.reduce!"a + b"(
        std.algorithm.map!(count)(validationSample[0]).array);

    writefln("Percentage correct: %f percent",
             num.to!double / validationSample[1].to!double * 100.0);
}
```

timeコマンドで測ってみる。

- 最適化なし

```
$ time ./knn                                           [kubo39:knn][git:master]
Percentage correct: 94.400000 percent
./knn  110.16s user 0.03s system 99% cpu 1:50.33 total
```

うーん、遅い。

- 最適化あり

```
$ time ./knn                                           [kubo39:knn][git:master]
Percentage correct: 94.400000 percent
./knn  90.50s user 0.06s system 99% cpu 1:30.59 total
```

少し早くなったけどぜんぜん遅い。

## Rustを見直し。

Rustのシングルスレッド版を再度測ってみる。

```
$ rustc --version                                      [kubo39:knn][git:master]
rustc 1.17.0-nightly (306035c21 2017-02-18)
```

少々手直しが必要。

```rust
use std::io::{BufRead, BufReader};
use std::fs::File;
use std::path::Path;
use std::str::FromStr;

struct LabelPixel {
    label: i32,
    pixels: Vec<i32>
}

fn slurp_file(file: &Path) -> Vec<LabelPixel> {
    BufReader::new(File::open(file).unwrap())
        .lines()
        .skip(1)
        .map(|line| {
            let line = line.unwrap();
            let mut iter = line.trim()
                .split(',')
                .map(|x| i32::from_str(x).unwrap());

            LabelPixel {
                label: iter.next().unwrap(),
                pixels: iter.collect()
            }
        })
        .collect()
}

fn distance_sqr(x: &[i32], y: &[i32]) -> i32 {
    // run through the two vectors, summing up the squares of the differences
    x.iter()
        .zip(y.iter())
        .fold(0, |s, (&a, &b)| s + (a - b) * (a - b))
}

fn classify(training: &[LabelPixel], pixels: &[i32]) -> i32 {
    training
        .iter()
        // find element of `training` with the smallest distance_sqr to `pixel`
        .min_by_key(|p| distance_sqr(p.pixels.as_slice(), pixels)).unwrap()
        .label
}

fn main() {
    let training_set = slurp_file(&Path::new("trainingsample.csv"));
    let validation_sample = slurp_file(&Path::new("validationsample.csv"));

    let num_correct = validation_sample.iter()
        .filter(|x| {
            classify(training_set.as_slice(), x.pixels.as_slice()) == x.label
        })
        .count();

    println!("Percentage correct: {}%",
             num_correct as f64 / validation_sample.len() as f64 * 100.0);
}
```

releaseビルド。めちゃくちゃ早い。。

```console
$ cargo build --release                              [kubo39:knnrs][git:master]
   Compiling knnrs v0.1.0 (file:///home/kubo39/dev/dlang/knn/knnrs)
    Finished release [optimized] target(s) in 2.6 secs
$ time ./target/release/knnrs                        [kubo39:knnrs][git:master]
Percentage correct: 94.39999999999999%
./target/release/knnrs  1.21s user 0.01s system 99% cpu 1.217 total
```

## D言語に戻る。

計測しやすいようにシングルスレッド版からはじめる。

```d
import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.stdio;
import std.string;
import std.typecons;

struct LabelPixel
{
    int label;
    int[] pixels;
}

auto slurpFile(string filename)
{
    int count;

    auto lp = File(filename)
        .byLine
        .dropOne
        .tee!(a => count++)
        .map!chomp
        .map!(a => a.to!string.split(","))
        .map!(a => LabelPixel(a[0].to!int, a[1..$].to!(int[])) )
        .array;
    return tuple(lp, count);
}

int distanceSqrt(const ref int[] x, const ref int[] y) pure
{
    return reduce!((a, b) => a + (b[0] - b[1]) * (b[0] - b[1]))(0, x.zip(y));
}

int classify(const ref LabelPixel[] training, const ref int[] pixels) pure
{
    int smallest = int.max;
    int result = void;

    foreach (t; training)
    {
        int tmp = distanceSqrt(t.pixels, pixels);
        if (tmp < smallest)
        {
            smallest = tmp;
            result = t.label;
        }
    }
    return result;
}

void main()
{
    const trainingSet = "trainingsample.csv".slurpFile;
    const validationSample = "validationsample.csv".slurpFile;

    int count(const LabelPixel data) pure
    {
        int num;
        if (classify(trainingSet[0], data.pixels) == data.label)
            num++;
        return num;
    }

    immutable num = reduce!"a + b"(
        std.algorithm.map!(count)(validationSample[0]).array);

    writefln("Percentage correct: %f percent",
             num.to!double / validationSample[1].to!double * 100.0);
}
```

シングルスレッド版のほうが早い。といってもあまり変わらないが。


```console
$ dmd -O knn.d                                         [kubo39:knn][git:master]
$ time ./knn                                           [kubo39:knn][git:master]
Percentage correct: 94.400000 percent
./knn  88.90s user 0.02s system 99% cpu 1:28.94 total
```

dmdだとだめそう。ldc2は理論値性能が出る？

http://leonardo-m.livejournal.com/111598.html

```console
$ ldc2 -version | head -2
LDC - the LLVM D compiler (1.0.0):
  based on DMD v2.071.2 and LLVM 3.8.1
```

最適化つきで計測。DMDよりぜんぜん速いけどRustより遅い。

```
$ ldc2 -O knn.d
$ time ./knn
Percentage correct: 94.400000 percent
./knn  10.76s user 0.02s system 99% cpu 10.794 total
```

# operf

operfはdwarf情報を使うので-gつけてビルド。

```console
$ ldc2 -O -g knn.d
$ sudo operf ./knn
operf: Profiler started
Percentage correct: 94.400000 percent

Profiling done.
```

`opannotate --source` をみると、distanceSqrt関数が14%を占めていることがわかる。

```
$ opannotate --source
[ ... ]
/* 
 * Total samples for file : "/home/kubo39/dev/dlang/knn/knn.d"
 * 
 *  45735 15.2286
 */


               :import std.algorithm;
               :import std.array;
               :import std.conv;
               :import std.range;
               :import std.stdio;
               :import std.string;
               :import std.typecons;
               :
               :struct LabelPixel
               :{
               :    int label;
               :    int[] pixels;
               :}
               :
               :auto slurpFile(string filename)
               :{
               :    int count;
               :
               :    auto lp = File(filename)
               :        .byLine
               :        .dropOne
               :        .tee!(a => count++)
               :        .map!chomp
               :        .map!(a => a.to!string.split(","))
               :        .map!(a => LabelPixel(a[0].to!int, a[1..$].to!(int[])) )
               :        .array;
               :    return tuple(lp, count);
               :}
               :
               :int distanceSqrt(const ref int[] x, const ref int[] y) pure
               :{
 45028 14.9931 :    return reduce!((a, b) => a + (b[0] - b[1]) * (b[0] - b[1]))(0, x.zip(y)); /* _D3knn12distanceSqrtFNaKxAiKxAiZi total: 165424 55.0818 */
               :}
               :
               :int classify(const ref LabelPixel[] training, const ref int[] pixels) pure
               :{
               :    int smallest = int.max;
               :    int result = void;
               :
   523  0.1741 :    foreach (t; training)
               :    {
    33  0.0110 :        int tmp = distanceSqrt(t.pixels, pixels);
    50  0.0166 :        if (tmp < smallest)
               :        {
               :            smallest = tmp;
               :            result = t.label;
               :        }
               :    }
               :    return result;
               :}
               :
               :void main()
               :{
               :    const trainingSet = "trainingsample.csv".slurpFile; /* _Dmain total:    711  0.2367 */
               :    const validationSample = "validationsample.csv".slurpFile;
               :
               :    int count(const LabelPixel data) pure
               :    {
               :        int num;
   101  0.0336 :        if (classify(trainingSet[0], data.pixels) == data.label)
               :            num++;
               :        return num;
               :    }
               :
               :    immutable num = reduce!"a + b"(
               :        std.algorithm.map!(count)(validationSample[0]).array);
               :
               :    writefln("Percentage correct: %f percent",
               :             num.to!double / validationSample[1].to!double * 100.0);
               :}
```

distanceSqrtの実装を変えてみる。

```
...
int distanceSqrt(const ref int[] x, const ref int[] y) pure
{
    int total;
    foreach (i, a; x)
        total += (a - y[i]) ^^ 2;
    return total;
}
...
```

4倍以上早くなった。

```console
$ ldc2 -O knn.d
$ time ./knn
Percentage correct: 94.400000 percent
./knn  2.45s user 0.01s system 99% cpu 2.463 total
```

その他シングルスレッド版では無駄な処理を省いてみる。

```d
import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.stdio;
import std.string;
import std.typecons;

struct LabelPixel
{
    int label;
    int[] pixels;
}

auto slurpFile(string filename)
{
    int count;

    return File(filename)
        .byLine
        .dropOne
        .map!chomp
        .map!(a => a.to!string.split(","))
        .map!(a => LabelPixel(a[0].to!int, a[1..$].to!(int[])) )
        .array;
}

int distanceSqrt(const ref int[] x, const ref int[] y) pure
{
    int total;
    foreach (i, a; x)
        total += (a - y[i]) ^^ 2;
    return total;
}

int classify(const ref LabelPixel[] training, const ref int[] pixels) pure
{
    int smallest = int.max;
    int result = void;

    foreach (t; training)
    {
        int tmp = distanceSqrt(t.pixels, pixels);
        if (tmp < smallest)
        {
            smallest = tmp;
            result = t.label;
        }
    }
    return result;
}

void main()
{
    const trainingSet = "trainingsample.csv".slurpFile;
    const validationSample = "validationsample.csv".slurpFile;

    immutable num = validationSample
        .filter!(a => classify(trainingSet, a.pixels) == a.label)
        .count;

    writefln("Percentage correct: %f percent",
             num.to!double / validationSample.length.to!double * 100.0);
}
```

うーむ、誤差程度。というか少し遅くなってる。

```console
$ ldc2 -O knn.d
$ time ./knn
Percentage correct: 94.400000 percent
./knn  2.52s user 0.00s system 99% cpu 2.528 total
```

もう一度operfをかけてみる。72%が二乗の処理らしい。

```
...
               :int distanceSqrt(const ref int[] x, const ref int[] y) pure
               :{
               :    int total;
  8513 13.5856 :    foreach (i, a; x)
 45571 72.7251 :        total += (a - y[i]) ^^ 2;
               :    return total;
               :}
...
```

operf --assemblyもしてみたがあまりわからなかった。

sub -> imul -> add -> inc の場所で60%以上喰ってるらしいが。。

```
000000000001a580 <_D3std9algorithm9iteration62__T12FilterResultS213knn4mainFZ9__lambda1TAxS3knn10LabelPixelZ12FilterResult8popFrontMFNaZv>: /* _D3std9algorithm9iteration62__T12FilterResultS213knn4mainFZ9__lambda1TAxS3knn10LabelPixelZ12FilterResult8popFrontMFNaZv total:  54369 86.7655 */
...
  4071  6.4968 :   1a600:	cmp    %rsi,%rbx
    21  0.0335 :   1a603:	jae    1a649 <_D3std9algorithm9iteration62__T12FilterResultS213knn4mainFZ9__lambda1TAxS3knn10LabelPixelZ12FilterResult8popFrontMFNaZv+0xc9>
  3182  5.0780 :   1a605:	mov    (%rcx,%rbx,4),%r8d
 14565 23.2438 :   1a609:	sub    (%rdx,%rbx,4),%r8d
  6849 10.9301 :   1a60d:	imul   %r8d,%r8d
 10065 16.0624 :   1a611:	add    %r8d,%ebp
  9923 15.8358 :   1a614:	inc    %rbx
  5268  8.4070 :   1a617:	cmp    %rax,%rbx
    35  0.0559 :   1a61a:	jb     1a600 <_D3std9algorithm9iteration62__T12FilterResultS213knn4mainFZ9__lambda1TAxS3knn10LabelPixelZ12FilterResult8popFrontMFNaZv+0x80>
...
```

そもそもなんでRustこんなはやいのか。

objdumpでみてみる。なるほど、SIMDでループをベクトル化してるのか。releaseビルドぱない。

```
    // run through the two vectors, summing up the squares of the differences
    x.iter()
        .zip(y.iter())
        .fold(0, |s, (&a, &b)| s + (a - b) * (a - b))
    8b80:       f3 0f 6f 0c b7          movdqu (%rdi,%rsi,4),%xmm1
    8b85:       f3 0f 6f 14 b2          movdqu (%rdx,%rsi,4),%xmm2
    8b8a:       66 0f fa ca             psubd  %xmm2,%xmm1
    8b8e:       66 0f 70 d1 f5          pshufd $0xf5,%xmm1,%xmm2
    8b93:       66 0f f4 c9             pmuludq %xmm1,%xmm1
    8b97:       66 0f 70 c9 e8          pshufd $0xe8,%xmm1,%xmm1
    8b9c:       66 0f f4 d2             pmuludq %xmm2,%xmm2
    8ba0:       66 0f 70 d2 e8          pshufd $0xe8,%xmm2,%xmm2
    8ba5:       66 0f 62 ca             punpckldq %xmm2,%xmm1
    8ba9:       66 0f fe c8             paddd  %xmm0,%xmm1
    8bad:       f3 0f 6f 44 b7 10       movdqu 0x10(%rdi,%rsi,4),%xmm0
    8bb3:       f3 0f 6f 54 b2 10       movdqu 0x10(%rdx,%rsi,4),%xmm2
    8bb9:       66 0f fa c2             psubd  %xmm2,%xmm0
    8bbd:       66 0f 70 d0 f5          pshufd $0xf5,%xmm0,%xmm2
    8bc2:       66 0f f4 c0             pmuludq %xmm0,%xmm0
    8bc6:       66 0f 70 c0 e8          pshufd $0xe8,%xmm0,%xmm0
    8bcb:       66 0f f4 d2             pmuludq %xmm2,%xmm2
    8bcf:       66 0f 70 d2 e8          pshufd $0xe8,%xmm2,%xmm2
```

## マルチスレッド

### D言語

- コード

std.parallelismを使った。スレッド数はいじっても差異はほとんどなかったのでデフォルトで。

```d
// ldc2 -O5 parallelknn.d
import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.stdio;
import std.string;
import std.parallelism;

struct LabelPixel
{
    int label;
    int[] pixels;
}

auto slurpFile(string filename)
{
    return File(filename)
        .byLine
        .dropOne
        .map!(a => a.chomp.to!string.split(","))
        .map!(a => LabelPixel(a[0].to!int, a[1..$].to!(int[])) )
        .array;
}

ulong distanceSqrt(const ref int[] x, const ref int[] y)
{
    ulong total;
    ulong i = 0;
    while (i < (x.length & ~7))
    {
        auto t0 = (x[i] - y[i]) ^^ 2;
        auto t1 = (x[i+1] - y[i+1]) ^^ 2;
        auto t2 = (x[i+2] - y[i+2]) ^^ 2;
        auto t3 = (x[i+3] - y[i+3]) ^^ 2;
        auto t4 = (x[i+4] - y[i+4]) ^^ 2;
        auto t5 = (x[i+5] - y[i+5]) ^^ 2;
        auto t6 = (x[i+6] - y[i+6]) ^^ 2;
        auto t7 = (x[i+7] - y[i+7]) ^^ 2;
        total += t0 + t1 + t2 + t3 + t4 + t5 + t6 + t7;
        i += 8;
    }
    for (ulong j = i; j< x.length; j++)
        total += (x[j] - y[j]) ^^ 2;
    return total;
}

int classify(const ref LabelPixel[] training, const ref int[] pixels) pure
{
    int smallest = int.max;
    int result = void;

    foreach (t; training)
    {
        int tmp = distanceSqrt(t.pixels, pixels);
        if (tmp < smallest)
        {
            smallest = tmp;
            result = t.label;
        }
    }
    return result;
}

void main()
{
    const trainingSet = "trainingsample.csv".slurpFile;
    const validationSample = "validationsample.csv".slurpFile;

    immutable num = taskPool.reduce!"a + b"(
        validationSample.filter!(a => classify(trainingSet, a.pixels) == a.label));

    writefln("Percentage correct: %f percent",
             num.to!double / validationSample.length.to!double * 100.0);
}
```

- ベンチマーク

```console
$ time ./knn                                           [kubo39:knn][git:master]
Percentage correct: 94.400000 percent
./knn  2.37s user 0.01s system 99% cpu 2.378 total
```

### Rust

- コード

lto(Link-Time Optimization)を有効にし、rayon crateを使った。

```rust
extern crate rayon;

use std::io::{BufRead, BufReader};
use std::fs::File;
use std::path::Path;
use std::str::FromStr;

use rayon::prelude::*;

struct LabelPixel {
    label: i32,
    pixels: Vec<i32>
}

fn slurp_file(file: &Path) -> Vec<LabelPixel> {
    BufReader::new(File::open(file).unwrap())
        .lines()
        .skip(1)
        .map(|line| {
            let line = line.unwrap();
            let mut iter = line.trim()
                .split(',')
                .map(|x| i32::from_str(x).unwrap());

            LabelPixel {
                label: iter.next().unwrap(),
                pixels: iter.collect()
            }
        })
        .collect()
}

#[inline(never)]
fn distance_sqr(x: &[i32], y: &[i32]) -> i32 {
    // run through the two vectors, summing up the squares of the differences
    x.iter()
        .zip(y.iter())
        .fold(0, |s, (&a, &b)| s + (a - b) * (a - b))
}

fn classify(training: &[LabelPixel], pixels: &[i32]) -> i32 {
    training
        .iter()
        // find element of `training` with the smallest distance_sqr to `pixel`
        .min_by_key(|p| distance_sqr(p.pixels.as_slice(), pixels)).unwrap()
        .label
}

fn main() {
    let training_set = slurp_file(&Path::new("trainingsample.csv"));
    let validation_sample = slurp_file(&Path::new("validationsample.csv"));

    let num_correct = validation_sample.par_iter()
        .filter(|x| {
            classify(training_set.as_slice(), x.pixels.as_slice()) == x.label
        })
        .count();

    println!("Percentage correct: {}%",
             num_correct as f64 / validation_sample.len() as f64 * 100.0);
}
```

- ベンチマーク

```console
$ time ./target/release/knnrs                        [kubo39:knnrs][git:master]
Percentage correct: 94.39999999999999%
./target/release/knnrs  2.07s user 0.02s system 353% cpu 0.590 total
```
