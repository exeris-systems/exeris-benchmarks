public class LayoutProbe {

    // --- all-primitive value classes, increasing payload ---
    static value class V4  { final int  a;                 V4(int a){this.a=a;} }
    static value class V8  { final int  a; final int  b;   V8(int a,int b){this.a=a;this.b=b;} }
    static value class V12 { final int  a; final long b;   V12(int a,long b){this.a=a;this.b=b;} }
    static value class V16 { final long a; final long b;   V16(long a,long b){this.a=a;this.b=b;} }
    static value class V32 { final long a,b,c,d;           V32(long a,long b,long c,long d){this.a=a;this.b=b;this.c=c;this.d=d;} }

    // --- reference-carrying value classes, straddling FlatArrayElementMaxOops = 4 ---
    static value class R2 { final String a, b;             R2(String a,String b){this.a=a;this.b=b;} }
    static value class R4 { final String a, b, c, d;       R4(String a,String b,String c,String d){this.a=a;this.b=b;this.c=c;this.d=d;} }
    static value class R5 { final String a, b, c, d, e;    R5(String a,String b,String c,String d,String e){this.a=a;this.b=b;this.c=c;this.d=d;this.e=e;} }

    // --- the shapes the kernel actually uses ---
    static value record FlowKeyLike(long hi, long lo) {}
    static value record HttpStatusLike(int code, String reason) {}
    static value record HttpHeaderLike(String name, String value) {}
    static value record EventDescriptorLike(long a, long b, long c, long d, int e, int f, long g) {}

    // --- holders: are these fields flattened into the enclosing object? ---
    static class HolderNullable {
        final V8  f8;   final V12 f12;  final V16 f16;  final V32 f32;
        final R2  r2;   final R5  r5;
        HolderNullable(V8 f8, V12 f12, V16 f16, V32 f32, R2 r2, R5 r5) {
            this.f8=f8; this.f12=f12; this.f16=f16; this.f32=f32; this.r2=r2; this.r5=r5;
        }
    }
    static value class HolderValue {
        final V8 f8; final V16 f16; final R2 r2;
        HolderValue(V8 f8, V16 f16, R2 r2){ this.f8=f8; this.f16=f16; this.r2=r2; }
    }

    public static void main(String[] args) {
        Object[] keep = {
            new V4(1), new V8(1,2), new V12(1,2L), new V16(1L,2L), new V32(1,2,3,4),
            new R2("a","b"), new R4("a","b","c","d"), new R5("a","b","c","d","e"),
            new FlowKeyLike(1,2), new HttpStatusLike(200,"OK"),
            new HttpHeaderLike("h","v"), new EventDescriptorLike(1,2,3,4,5,6,7),
            new HolderNullable(new V8(1,2), new V12(1,2), new V16(1,2), new V32(1,2,3,4),
                               new R2("a","b"), new R5("a","b","c","d","e")),
            new HolderValue(new V8(1,2), new V16(1,2), new R2("a","b")),
            // arrays: the container that can actually flatten
            new V4[2], new V8[2], new V12[2], new V16[2], new V32[2],
            new R2[2], new R4[2], new R5[2],
            new FlowKeyLike[2], new HttpStatusLike[2], new HttpHeaderLike[2], new EventDescriptorLike[2],
        };
        System.out.println("probe objects: " + keep.length);
    }
}
